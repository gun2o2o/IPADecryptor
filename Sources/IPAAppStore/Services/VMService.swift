import Foundation
import SwiftUI
import AppKit

final class VMService {
    @AppStorage("workspacePath") var workspacePath = ""
    @AppStorage("sshHost") private var sshHost = "127.0.0.1"
    @AppStorage("sshPort") private var sshPort = "2222"
    @AppStorage("sshPassword") private var sshPassword = "alpine"
    @AppStorage("vphoneVersion") var vphoneVersion = "stable"

    var vphoneDir: String { wp("vphone") }
    var venvDir: String { wp("vphone") + "/.venv" }  // share vphone's venv
    var ipaOutputDir: String { wp("decrypted_ipas") }
    var fridaDumpDir: String { wp("frida-ios-dump") }
    private func wp(_ sub: String) -> String { (workspacePath as NSString).appendingPathComponent(sub) }

    private var sshpassPath: String {
        for p in ["/opt/homebrew/bin/sshpass", "/usr/local/bin/sshpass"] {
            if FileManager.default.fileExists(atPath: p) { return p }
        }
        return "sshpass"
    }

    private let vmPath = "export PATH=/var/jb/usr/local/bin:/var/jb/usr/bin:/var/jb/usr/sbin:/var/jb/bin:/var/jb/sbin:$PATH"

    /// Shared log store — views observe this
    var logStore: LogStore?

    private func log(_ text: String, isError: Bool = false, tabId: UUID? = nil) {
        if let tid = tabId {
            Task { @MainActor in logStore?.append(to: tid, text, isError: isError) }
        } else {
            Task { @MainActor in logStore?.append(text, isError: isError) }
        }
    }

    private var vphoneGitRef: String {
        vphoneVersion == "stable" ? "a7dd34f" : "main"
    }

    // MARK: - Check Groups

    func checkSIP() async -> Bool {
        let (out, _, _) = (try? await shell("/usr/bin/csrutil", args: ["status"])) ?? ("", "", 1)
        return out.lowercased().contains("disabled")
    }

    func checkDependencies() async -> (Bool, String?) {
        // Returns (allOK, firstFailedStep)
        if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") { return (false, DepStep.homebrew.rawValue) }
        for bin in ["aria2c", "ipsw", "sshpass", "ldid", "autoconf", "automake", "pkg-config", "cmake"] {
            if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/\(bin)") { return (false, DepStep.brewPackages.rawValue) }
        }
        if !FileManager.default.fileExists(atPath: vphoneDir + "/.build/release/vphone-cli") { return (false, DepStep.vphoneCLI.rawValue) }
        if !FileManager.default.fileExists(atPath: venvDir + "/bin/frida") { return (false, DepStep.pythonVenv.rawValue) }
        if !FileManager.default.fileExists(atPath: fridaDumpDir + "/dump.py") { return (false, DepStep.pythonVenv.rawValue) }
        if !FileManager.default.fileExists(atPath: vphoneDir + "/vm/Disk.img") { return (false, DepStep.vmCreated.rawValue) }
        // Check fw_patch_jb completed (kernelcache patched)
        let fwDir = vphoneDir + "/vm"
        let hasPatched = FileManager.default.fileExists(atPath: fwDir + "/iPhone17,3_26.1_23B85_Restore")
        if !hasPatched { return (false, DepStep.firmware.rawValue) }
        return (true, nil)
    }

    func checkVMSetup() async -> (Bool, String?) {
        let vmDir = vphoneDir + "/vm"
        let diskPath = vmDir + "/Disk.img"
        let actualSize = diskActualSize(diskPath)
        if actualSize < 1_000_000_000 { return (false, "Firmware not installed") }
        if !FileManager.default.fileExists(atPath: vmDir + "/nvram.bin") { return (false, "CFW not installed") }
        // First boot done = actual disk usage grew beyond 10GB (JB init writes data)
        if actualSize < 10_000_000_000 { return (false, "First boot not done") }

        // VM setup is complete — runtime checks (VM running, SSH, frida) are for Launch VM
        return (true, nil)
    }

    // MARK: - Fix Dependencies (all-in-one, resumable)

    /// Paths to user-imported IPSW files (set by ViewModel before calling)
    var iphoneIPSWPath: String?
    var cloudOSIPSWPath: String?

    func fixDependencies(onProgress: @escaping (Int, Int, String, String) -> Void) async throws {
        let steps = DepStep.allCases
        let total = steps.count

        for (i, step) in steps.enumerated() {
            let stepNum = i + 1

            // Check if this step is already done
            if await isDepStepDone(step) {
                onProgress(stepNum, total, step.rawValue, "Already done")
                continue
            }

            onProgress(stepNum, total, step.rawValue, "Installing...")

            switch step {
            case .homebrew:
                if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew") {
                    let (_, _, exit) = try await shell("/bin/bash", args: ["-c",
                        "NONINTERACTIVE=1 /bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""])
                    if exit != 0 { throw AppError.shellFailed("Homebrew install failed. Install manually.") }
                }

            case .brewPackages:
                onProgress(stepNum, total, step.rawValue, "Installing brew packages...")
                let (_, err, exit) = try await shell("/opt/homebrew/bin/brew", args: [
                    "install", "aria2", "wget", "gnu-tar", "openssl@3", "ldid-procursus",
                    "sshpass", "keystone", "libusb", "ipsw", "zstd",
                    "autoconf", "automake", "pkg-config", "cmake", "libtool",
                    "libimobiledevice", "ideviceinstaller"
                ])
                if exit != 0 { throw AppError.shellFailed("brew install failed: \(err.prefix(150))") }

            case .pythonVenv:
                // Install our packages into vphone's .venv (already created by make setup_tools)
                let pip = venvDir + "/bin/pip3"
                guard FileManager.default.fileExists(atPath: pip) else {
                    throw AppError.shellFailed("vphone venv not found. Fix vphone-cli first.")
                }

                onProgress(stepNum, total, step.rawValue, "Installing frida-tools + pymobiledevice3...")
                let (_, e2s, e2) = try await shell(pip, args: ["install", "frida-tools", "pymobiledevice3==9.9.0"])
                if e2 != 0 { throw AppError.shellFailed("pip install failed: \(e2s.prefix(150))") }

                onProgress(stepNum, total, step.rawValue, "Cloning frida-ios-dump...")
                if !FileManager.default.fileExists(atPath: fridaDumpDir) {
                    let (_, _, e3) = try await shell("/usr/bin/git", args: ["clone", "--depth=1",
                        "https://github.com/AloneMonkey/frida-ios-dump.git", fridaDumpDir])
                    if e3 != 0 { throw AppError.shellFailed("git clone frida-ios-dump failed") }
                }
                let (_, _, e4) = try await shell(pip, args: ["install", "-r", fridaDumpDir + "/requirements.txt"])
                if e4 != 0 { throw AppError.shellFailed("pip install frida deps failed") }

            case .vphoneCLI:
                if !FileManager.default.fileExists(atPath: vphoneDir) {
                    onProgress(stepNum, total, step.rawValue, "Cloning vphone-cli...")
                    let (_, _, e1) = try await shell("/usr/bin/git", args: [
                        "clone", "--recurse-submodules",
                        "https://github.com/Lakr233/vphone-cli.git", vphoneDir
                    ])
                    if e1 != 0 { throw AppError.shellFailed("git clone vphone-cli failed") }

                    // Checkout specific version
                    onProgress(stepNum, total, step.rawValue, "Checking out \(vphoneGitRef)...")
                    let (_, _, e1b) = try await shellInDir(vphoneDir, "/usr/bin/git", args: ["checkout", vphoneGitRef])
                    if e1b != 0 { throw AppError.shellFailed("git checkout \(vphoneGitRef) failed") }
                    let (_, _, e1c) = try await shellInDir(vphoneDir, "/usr/bin/git", args: ["submodule", "update", "--init", "--recursive"])
                    if e1c != 0 { throw AppError.shellFailed("git submodule update failed") }
                }
                onProgress(stepNum, total, step.rawValue, "Building tools...")
                // Use system Python 3.9 for venv (pymobiledevice3 segfaults on 3.12)
                let (_, e2s, e2) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["setup_tools"])
                if e2 != 0 { throw AppError.shellFailed("make setup_tools failed: \(e2s.prefix(150))") }

                onProgress(stepNum, total, step.rawValue, "Building vphone-cli...")
                let (_, e3s, e3) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["build"])
                if e3 != 0 { throw AppError.shellFailed("make build failed: \(e3s.prefix(150))") }

            case .vmCreated:
                onProgress(stepNum, total, step.rawValue, "Creating VM image...")
                let (_, es, e) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["vm_new", "CPU=4", "MEMORY=4096", "DISK_SIZE=64"])
                if e != 0 { throw AppError.shellFailed("make vm_new failed: \(es.prefix(150))") }

            case .firmware:
                // Check if user has imported firmware files
                let ipswDir = vphoneDir + "/ipsws"
                let hasIphone = !(iphoneIPSWPath ?? "").isEmpty && FileManager.default.fileExists(atPath: iphoneIPSWPath ?? "")
                let hasCloudOS = !(cloudOSIPSWPath ?? "").isEmpty && FileManager.default.fileExists(atPath: cloudOSIPSWPath ?? "")

                if !hasIphone || !hasCloudOS {
                    var missing: [String] = []
                    if !hasIphone { missing.append("iPhone IPSW (10.78 GB)") }
                    if !hasCloudOS { missing.append("cloudOS IPSW (935 MB)") }
                    throw AppError.firmwareFilesNeeded(
                        missing: missing,
                        iphoneURL: "https://updates.cdn-apple.com/2025FallFCS/fullrestores/089-13864/668EFC0E-5911-454C-96C6-E1063CB80042/iPhone17,3_26.1_23B85_Restore.ipsw",
                        cloudOSURL: "https://updates.cdn-apple.com/private-cloud-compute/399b664dd623358c3de118ffc114e42dcd51c9309e751d43bc949b98f4e31349",
                        targetDir: ipswDir
                    )
                }

                onProgress(stepNum, total, step.rawValue, "Preparing firmware...")
                let (_, e1s, e1) = try await shellInDir(
                    vphoneDir, "/usr/bin/make", args: [
                        "fw_prepare",
                        "IPHONE_SOURCE=\(iphoneIPSWPath!)",
                        "CLOUDOS_SOURCE=\(cloudOSIPSWPath!)"
                    ]
                )
                if e1 != 0 { throw AppError.shellFailed("fw_prepare failed: \(e1s.prefix(150))") }
                onProgress(stepNum, total, step.rawValue, "Patching firmware (jailbreak)...")
                let (_, e2s, e2) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["fw_patch_jb"])
                if e2 != 0 { throw AppError.shellFailed("fw_patch_jb failed: \(e2s.prefix(150))") }
            }
        }
    }

    // MARK: - Hybrid VM Setup (auto + sudo pause)

    /// Callback: called when sudo is needed. Provides the command string.
    /// Returns when user has completed the command.
    var onSudoNeeded: ((VMSetupStep, String) async -> Void)?

    /// Runs the full VM setup. Auto-runs non-sudo steps, pauses for sudo steps.
    func runVMSetup(onStep: @escaping (VMSetupStep, StepStatus) -> Void) async throws {
        let envPath = "\(vphoneDir)/.local_bin:\(venvDir)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        let fm = FileManager.default
        let vmDir = vphoneDir + "/vm"

        // --- Check completion markers to resume from where we left off ---
        let hasShsh = (try? fm.contentsOfDirectory(atPath: vmDir + "/shsh"))?.contains(where: { $0.hasSuffix(".shsh") }) ?? false
        let diskSize = (try? fm.attributesOfItem(atPath: vmDir + "/Disk.img"))?[.size] as? Int64 ?? 0
        let restoreDone = hasShsh && diskSize > 1_000_000_000
        let ramdiskDone = fm.fileExists(atPath: vmDir + "/Ramdisk")
        let cfwDone = fm.fileExists(atPath: vmDir + "/nvram.bin")

        // Steps 1-2: Restore
        if restoreDone {
            onStep(.bootDFU, .done)
            onStep(.restore, .done)
            onStep(.restartDFU, .done)
        } else {
            let dfuTab = await MainActor.run { logStore?.createTab(name: "DFU Boot") }

            onStep(.bootDFU, .running("Starting DFU mode..."))
            let dfu1 = startBG(exe: "/usr/bin/make", args: ["boot_dfu"], dir: vphoneDir, envPath: envPath, tabId: dfuTab)
            try await Task.sleep(nanoseconds: 10_000_000_000)
            guard dfu1.isRunning else { throw AppError.shellFailed("boot_dfu failed to start") }
            onStep(.bootDFU, .done)

            onStep(.restore, .running("Getting SHSH..."))
            let (_, e1s, e1) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["restore_get_shsh"])
            if e1 != 0 { dfu1.terminate(); throw AppError.shellFailed("restore_get_shsh: \(e1s.prefix(100))") }

            onStep(.restore, .running("Restoring firmware..."))
            let (_, e2s, e2) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["restore"])
            dfu1.terminate()
            if let t = dfuTab { await MainActor.run { logStore?.finishTab(t) } }
            if e2 != 0 { throw AppError.shellFailed("restore: \(e2s.prefix(100))") }
            onStep(.restore, .done)
            onStep(.restartDFU, .done)
        }

        // Step 4: Ramdisk Build
        if ramdiskDone {
            onStep(.ramdiskBuild, .done)
        } else {
            // Need DFU running for ramdisk_build
            let dfuTab2 = await MainActor.run { logStore?.createTab(name: "DFU Boot") }
            onStep(.restartDFU, .running("Starting DFU for ramdisk..."))
            let dfu2 = startBG(exe: "/usr/bin/make", args: ["boot_dfu"], dir: vphoneDir, envPath: envPath, tabId: dfuTab2)
            try await Task.sleep(nanoseconds: 10_000_000_000)
            guard dfu2.isRunning else { throw AppError.shellFailed("boot_dfu failed") }
            onStep(.restartDFU, .done)

            let ramdiskCmd = "cd \(vphoneDir) && sudo env PATH=\"$PATH:/opt/homebrew/bin\" make ramdisk_build"
            onStep(.ramdiskBuild, .needsSudo(ramdiskCmd))
            await onSudoNeeded?(.ramdiskBuild, ramdiskCmd)
            onStep(.ramdiskBuild, .done)

            // Step 5: Ramdisk Send
            onStep(.ramdiskSend, .running("Sending ramdisk..."))
            if !dfu2.isRunning {
                dfu2.terminate()
                let dfu2b = startBG(exe: "/usr/bin/make", args: ["boot_dfu"], dir: vphoneDir, envPath: envPath, tabId: dfuTab2)
                try await Task.sleep(nanoseconds: 10_000_000_000)
                let (_, e3s, e3) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["ramdisk_send"])
                dfu2b.terminate()
                if e3 != 0 { throw AppError.shellFailed("ramdisk_send: \(e3s.prefix(100))") }
            } else {
                let (_, e3s, e3) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["ramdisk_send"])
                dfu2.terminate()
                if e3 != 0 { throw AppError.shellFailed("ramdisk_send: \(e3s.prefix(100))") }
            }
            if let t = dfuTab2 { await MainActor.run { logStore?.finishTab(t) } }
            onStep(.ramdiskSend, .done)
        }

        // Also mark ramdisk_send done if we skipped it
        if ramdiskDone { onStep(.ramdiskSend, .done) }

        // Step 6: CFW Install
        if cfwDone {
            onStep(.cfwInstall, .done)
        } else {
            let cfwTab = await MainActor.run { logStore?.createTab(name: "CFW Install") }
            onStep(.cfwInstall, .running("Preparing CFW install..."))

            let dfu3 = startBG(exe: "/usr/bin/make", args: ["boot_dfu"], dir: vphoneDir, envPath: envPath, tabId: cfwTab)
            try await Task.sleep(nanoseconds: 10_000_000_000)
            let (_, _, _) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["ramdisk_send"])

            let fwd = startBG(exe: venvDir + "/bin/python3",
                              args: ["-m", "pymobiledevice3", "usbmux", "forward", sshPort, "22"],
                              dir: vphoneDir, envPath: envPath)
            try await Task.sleep(nanoseconds: 3_000_000_000)

            let cfwCmd = "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer && cd \(vphoneDir) && make cfw_install_jb"
            onStep(.cfwInstall, .needsSudo(cfwCmd))
            await onSudoNeeded?(.cfwInstall, cfwCmd)

            fwd.terminate(); dfu3.terminate()
            if let t = cfwTab { await MainActor.run { logStore?.finishTab(t) } }
            onStep(.cfwInstall, .done)
        }

        // Step 7: Fix passwords
        onStep(.fixPasswords, .running("Fixing SSH passwords..."))
        try await fixPasswords(envPath: envPath)
        onStep(.fixPasswords, .done)

        // Step 8: First boot — JB initialization causes kernel panic (expected)
        // Boot → panic → kill → boot again → JB completes → actual disk usage grows past 10GB
        let currentDiskSize = diskActualSize(vmDir + "/Disk.img")
        let firstBootDone = currentDiskSize > 10_000_000_000
        if firstBootDone {
            onStep(.firstBoot, .done)
        } else {
            // First boot: JB initialization script runs and causes kernel panic.
            // We boot → detect panic → kill → boot again → this time JB is done → success.
            let logFile = vmDir + "/boot.log"
            let maxAttempts = 3

            for attempt in 1...maxAttempts {
                onStep(.firstBoot, .running("Boot attempt \(attempt)/\(maxAttempts)..."))
                let tab = await MainActor.run { logStore?.createTab(name: "First Boot #\(attempt)") }

                FileManager.default.createFile(atPath: logFile, contents: nil)
                let bootProc = startBGWithLogFile(
                    exe: "/usr/bin/make", args: ["boot"], dir: vphoneDir,
                    envPath: envPath, logFile: logFile, tabId: tab
                )

                // Wait and monitor for panic or successful boot (up to 3 min)
                var booted = false
                for _ in 0..<90 { // 90 × 2s = 3 min
                    try await Task.sleep(nanoseconds: 2_000_000_000)

                    if !bootProc.isRunning {

                        break
                    }

                    if let content = try? String(contentsOfFile: logFile, encoding: .utf8) {
                        if content.contains("panic.apple.com") || content.contains("Stackshot Succeeded") {
    
                            break
                        }
                        // Check for successful boot indicators
                        if content.contains("SpringBoard") || content.contains("backboardd") {
                            booted = true
                            break
                        }
                    }

                    // Check actual disk growth as sign of progress (sparse file!)
                    let diskSize = diskActualSize(vmDir + "/Disk.img")
                    if diskSize > 10_000_000_000 { // >10GB actual usage means iOS is writing
                        booted = true
                        break
                    }
                }

                if booted {
                    // Success! VM booted. Kill it (first boot done, Launch VM will restart)
                    if bootProc.isRunning { bootProc.terminate() }
                    _ = try? await shell("/usr/bin/pkill", args: ["-9", "-f", "vphone-cli"])
                    try await Task.sleep(nanoseconds: 3_000_000_000)
                    if let t = tab { await MainActor.run { logStore?.finishTab(t) } }
                    onStep(.firstBoot, .done)
                    return // Exit the function — setup complete
                }

                // Panic or timeout — kill and retry
                onStep(.firstBoot, .running("Panic detected. Restarting (attempt \(attempt)/\(maxAttempts))..."))
                if bootProc.isRunning { bootProc.terminate() }
                try await Task.sleep(nanoseconds: 2_000_000_000)
                _ = try? await shell("/usr/bin/pkill", args: ["-9", "-f", "vphone-cli"])
                try await Task.sleep(nanoseconds: 3_000_000_000)
                if let t = tab { await MainActor.run { logStore?.finishTab(t) } }
            }

            // All attempts exhausted
            onStep(.firstBoot, .failed("Failed after \(maxAttempts) boot attempts"))
            throw AppError.shellFailed("VM failed to boot after \(maxAttempts) attempts. JB initialization may have failed.")
        }
    }

    // MARK: - Launch VM (auto)

    func launchVM(onStep: @escaping (String) -> Void) async throws {
        let envPath = "\(vphoneDir)/.local_bin:\(venvDir)/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

        // Check if VM is already running
        let (pout, _, _) = (try? await shell("/usr/bin/pgrep", args: ["-f", "vphone-cli"])) ?? ("", "", 1)
        if !pout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            onStep("VM already running. Starting SSH forward...")
            // Just ensure SSH forward is running
            _ = startBG(exe: venvDir + "/bin/python3",
                        args: ["-m", "pymobiledevice3", "usbmux", "forward", sshPort, "22"],
                        dir: vphoneDir, envPath: envPath)
            try await Task.sleep(nanoseconds: 3_000_000_000)
            onStep("VM ready")
            return
        }

        // Kill any lingering vphone processes to avoid "Failed to lock auxiliary storage"
        terminateAll()
        _ = try? await shell("/usr/bin/pkill", args: ["-9", "-f", "vphone-cli"])
        try await Task.sleep(nanoseconds: 2_000_000_000)

        onStep("Booting VM...")
        let vmTab = await MainActor.run { logStore?.createTab(name: "Virtual iPhone") }
        // Use log file instead of pipes — GUI app needs free stdout for window rendering
        let logFile = vphoneDir + "/vm/boot.log"
        _ = startBGWithLogFile(exe: "/usr/bin/make", args: ["boot"], dir: vphoneDir, envPath: envPath, logFile: logFile, tabId: vmTab)
        try await Task.sleep(nanoseconds: 15_000_000_000)

        onStep("Starting SSH forward...")
        let fwdTab = await MainActor.run { logStore?.createTab(name: "SSH Forward") }
        _ = startBG(exe: venvDir + "/bin/python3",
                    args: ["-m", "pymobiledevice3", "usbmux", "forward", sshPort, "22"],
                    dir: vphoneDir, envPath: envPath, tabId: fwdTab)
        try await Task.sleep(nanoseconds: 5_000_000_000)
        onStep("VM ready")
    }

    // MARK: - Fix passwords

    private func fixPasswords(envPath: String) async throws {
        let dfu = startBG(exe: "/usr/bin/make", args: ["boot_dfu"], dir: vphoneDir, envPath: envPath)
        try await Task.sleep(nanoseconds: 10_000_000_000)

        let (_, _, rs) = try await shellInDir(vphoneDir, "/usr/bin/make", args: ["ramdisk_send"])
        if rs != 0 { dfu.terminate(); return }

        let fwd = startBG(exe: venvDir + "/bin/python3",
                          args: ["-m", "pymobiledevice3", "usbmux", "forward", "2222", "22"],
                          dir: vphoneDir, envPath: envPath)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        let sshCmd: (String) async throws -> Void = { [sshpassPath, sshHost] cmd in
            _ = try? await self.shell(sshpassPath, args: ["-p", "alpine", "ssh", "-p", "2222",
                "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                "root@\(sshHost)", cmd])
        }

        try await sshCmd("/bin/mkdir -p /mnt1 && /sbin/mount_apfs /dev/disk1s1 /mnt1")
        try await sshCmd("sed -i.bak 's|^root:[^:]*:\\(.*\\):/bin/sh|root:/smx7MYTQIi2M:\\1:/var/jb/bin/sh|' /mnt1/etc/master.passwd && sed -i '' 's|^mobile:[^:]*:\\(.*\\):/bin/sh|mobile:/smx7MYTQIi2M:\\1:/var/jb/bin/sh|' /mnt1/etc/master.passwd")
        try await sshCmd("/sbin/umount /mnt1 && /sbin/reboot")

        fwd.terminate(); dfu.terminate()
        try await Task.sleep(nanoseconds: 3_000_000_000)
    }

    // MARK: - Background Process Management

    private var runningProcesses: [Process] = []

    /// Terminate all background processes (called on app exit)
    func terminateAll() {
        for p in runningProcesses where p.isRunning {
            p.terminate()
        }
        runningProcesses.removeAll()
    }

    /// Start GUI process with log file (for vphone boot — needs free stdout for window)
    func startBGWithLogFile(exe: String, args: [String], dir: String, envPath: String, logFile: String, tabId: UUID? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        // Write to log file instead of pipe — GUI apps need stdout unblocked
        let logHandle = FileHandle(forWritingAtPath: logFile) ?? {
            FileManager.default.createFile(atPath: logFile, contents: nil)
            return FileHandle(forWritingAtPath: logFile)!
        }()
        logHandle.seekToEndOfFile()
        p.standardOutput = logHandle
        p.standardError = logHandle
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = envPath
        env["VIRTUAL_ENV"] = venvDir
        p.environment = env
        try? p.run()
        runningProcesses.append(p)

        // Tail the log file to feed our console
        if let tabId = tabId {
            tailLogFile(logFile, tabId: tabId)
        }
        return p
    }

    /// Monitor a log file and stream new content to a console tab
    private func tailLogFile(_ path: String, tabId: UUID) {
        DispatchQueue.global().async { [weak self] in
            var offset: UInt64 = 0
            while true {
                guard let fh = FileHandle(forReadingAtPath: path) else {
                    Thread.sleep(forTimeInterval: 1); continue
                }
                fh.seek(toFileOffset: offset)
                let data = fh.readDataToEndOfFile()
                offset += UInt64(data.count)
                fh.closeFile()
                if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                    self?.log(text, tabId: tabId)
                }
                Thread.sleep(forTimeInterval: 1)
                // Stop if no process references this
                if self == nil { break }
            }
        }
    }

    func startBG(exe: String, args: [String], dir: String, envPath: String, tabId: UUID? = nil) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: dir)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        outPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData; guard !d.isEmpty, let t = String(data: d, encoding: .utf8) else { return }
            self?.log(t, isError: false, tabId: tabId)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData; guard !d.isEmpty, let t = String(data: d, encoding: .utf8) else { return }
            self?.log(t, isError: true, tabId: tabId)
        }
        var env = ProcessInfo.processInfo.environment
        env["HOME"] = NSHomeDirectory()
        env["PATH"] = envPath
        env["VIRTUAL_ENV"] = venvDir
        p.environment = env
        try? p.run()
        runningProcesses.append(p)
        runningProcesses.removeAll { !$0.isRunning } // cleanup dead ones
        return p
    }

    // MARK: - Check individual dep step

    private func isDepStepDone(_ step: DepStep) async -> Bool {
        switch step {
        case .homebrew: return FileManager.default.fileExists(atPath: "/opt/homebrew/bin/brew")
        case .brewPackages:
            for bin in ["aria2c", "ipsw", "sshpass", "ldid", "autoconf", "automake", "pkg-config", "cmake"] {
                if !FileManager.default.fileExists(atPath: "/opt/homebrew/bin/\(bin)") { return false }
            }
            return true
        case .pythonVenv:
            return FileManager.default.fileExists(atPath: venvDir + "/bin/frida")
                && FileManager.default.fileExists(atPath: fridaDumpDir + "/dump.py")
        case .vphoneCLI:
            return FileManager.default.fileExists(atPath: vphoneDir + "/.build/release/vphone-cli")
        case .vmCreated:
            return FileManager.default.fileExists(atPath: vphoneDir + "/vm/Disk.img")
        case .firmware:
            return FileManager.default.fileExists(atPath: vphoneDir + "/vm/Ramdisk")
        }
    }

    // MARK: - Terminal Commands (for sudo dialog)

    // MARK: - App List

    func listInstalledApps() async throws -> [InstalledApp] {
        let script = """
        for plist in /var/containers/Bundle/Application/*/*.app/Info.plist; do
            [ -f "$plist" ] || continue
            bid=$(plutil -extract CFBundleIdentifier raw "$plist" 2>/dev/null) || continue
            name=$(plutil -extract CFBundleDisplayName raw "$plist" 2>/dev/null || plutil -extract CFBundleName raw "$plist" 2>/dev/null || echo "$bid")
            ver=$(plutil -extract CFBundleShortVersionString raw "$plist" 2>/dev/null || echo "?")
            appdir=$(dirname "$plist")
            case "$bid" in com.apple.*) continue;; esac
            echo "${bid}|||${name}|||${ver}|||${appdir}"
        done
        """
        let result = try await ssh(script)
        var apps: [InstalledApp] = []
        for line in result.components(separatedBy: .newlines) {
            let parts = line.split(separator: "|||", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 4, !parts[0].isEmpty else { continue }
            apps.append(InstalledApp(bundleId: parts[0], name: parts[1], version: parts[2], path: parts[3]))
        }
        return apps.sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    // MARK: - Actions

    func openVNC() { NSWorkspace.shared.open(URL(string: "vnc://127.0.0.1:5901")!) }
    func launchApp(bundleId: String) async throws {
        _ = try await ssh("\(vmPath); uiopen '\(esc(bundleId))' 2>&1 || true")
    }

    func resetWorkspace() throws {
        let path = workspacePath
        guard !path.isEmpty else { return }
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    }

    // MARK: - SSH

    @discardableResult
    func ssh(_ cmd: String) async throws -> String {
        let (out, stderr, exit) = try await shell(sshpassPath, args: ["-p", sshPassword] + sshArgs(cmd))
        if exit != 0 && !stderr.isEmpty { print("[SSH] \(stderr.prefix(200))") }
        return out
    }

    private func sshArgs(_ cmd: String) -> [String] {
        ["ssh", "-p", sshPort, "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
         "-o", "PreferredAuthentications=password", "-o", "ConnectTimeout=10",
         "-o", "ServerAliveInterval=30", "root@\(sshHost)", cmd]
    }

    func shell(_ exe: String, args: [String]) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
                var env = ProcessInfo.processInfo.environment; env["HOME"] = NSHomeDirectory()
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                p.environment = env
                do {
                    try p.run(); p.waitUntilExit()
                    cont.resume(returning: (
                        String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                        String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                        p.terminationStatus))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    func shellInDirWithEnv(_ dir: String, _ exe: String, args: [String], extraPath: String) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { [vphoneDir] in
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
                var env = ProcessInfo.processInfo.environment; env["HOME"] = NSHomeDirectory()
                env["PATH"] = "\(extraPath):\(vphoneDir)/.venv/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                env["VIRTUAL_ENV"] = "\(vphoneDir)/.venv"
                p.environment = env
                do {
                    try p.run(); p.waitUntilExit()
                    cont.resume(returning: (
                        String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                        String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
                        p.terminationStatus))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    func shellInDir(_ dir: String, _ exe: String, args: [String]) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { [weak self, vphoneDir] cont in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                let o = Pipe(), e = Pipe(); p.standardOutput = o; p.standardError = e
                var ao = Data(), ae = Data()
                o.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; guard !d.isEmpty else { return }; ao.append(d)
                    if let t = String(data: d, encoding: .utf8) { self?.log(t) }
                }
                e.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; guard !d.isEmpty else { return }; ae.append(d)
                    if let t = String(data: d, encoding: .utf8) { self?.log(t, isError: true) }
                }
                var env = ProcessInfo.processInfo.environment; env["HOME"] = NSHomeDirectory()
                env["PATH"] = "\(vphoneDir)/.venv/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                env["VIRTUAL_ENV"] = "\(vphoneDir)/.venv"
                p.environment = env
                do {
                    try p.run(); p.waitUntilExit()
                    o.fileHandleForReading.readabilityHandler = nil
                    e.fileHandleForReading.readabilityHandler = nil
                    ao.append(o.fileHandleForReading.readDataToEndOfFile())
                    ae.append(e.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: (
                        String(data: ao, encoding: .utf8) ?? "",
                        String(data: ae, encoding: .utf8) ?? "",
                        p.terminationStatus))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Shell in directory with real-time line output
    func shellInDirWithProgress(
        _ dir: String, _ exe: String, args: [String],
        onLine: @escaping (String) -> Void
    ) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async { [vphoneDir] in
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                p.currentDirectoryURL = URL(fileURLWithPath: dir)
                let op = Pipe(), ep = Pipe(); p.standardOutput = op; p.standardError = ep
                var env = ProcessInfo.processInfo.environment; env["HOME"] = NSHomeDirectory()
                env["PATH"] = "\(vphoneDir)/.venv/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                env["VIRTUAL_ENV"] = "\(vphoneDir)/.venv"
                p.environment = env
                var ao = Data(), ae = Data()
                // aria2c uses \r for progress updates, so split on both \n and \r
                op.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; guard !d.isEmpty else { return }; ao.append(d)
                    if let t = String(data: d, encoding: .utf8) {
                        for l in t.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\r"))) {
                            if !l.isEmpty { onLine(l) }
                        }
                    }
                }
                ep.fileHandleForReading.readabilityHandler = { h in
                    let d = h.availableData; guard !d.isEmpty else { return }; ae.append(d)
                    if let t = String(data: d, encoding: .utf8) {
                        for l in t.components(separatedBy: CharacterSet.newlines.union(CharacterSet(charactersIn: "\r"))) {
                            if !l.isEmpty { onLine(l) }
                        }
                    }
                }
                do {
                    try p.run(); p.waitUntilExit()
                    op.fileHandleForReading.readabilityHandler = nil
                    ep.fileHandleForReading.readabilityHandler = nil
                    ao.append(op.fileHandleForReading.readDataToEndOfFile())
                    ae.append(ep.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: (
                        String(data: ao, encoding: .utf8) ?? "",
                        String(data: ae, encoding: .utf8) ?? "",
                        p.terminationStatus))
                } catch { cont.resume(throwing: error) }
            }
        }
    }

    /// Parse aria2c progress line: [#abc 452MiB/892MiB(50%) CN:16 DL:10MiB]
    static func parseAria2Progress(_ line: String) -> String? {
        // Strip ANSI escape codes first
        let clean = line.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
        let l = clean
        guard l.contains("DL:") || l.contains("MiB/") || l.contains("GiB/") || l.contains("KiB/") else {
            return nil
        }

        var downloaded = ""
        var total = ""
        var speed = ""

        // Extract downloaded/total: e.g. "452MiB/892MiB"
        if let sizeRange = l.range(of: #"\d+[\.\d]*[KMG]iB/\d+[\.\d]*[KMG]iB"#, options: .regularExpression) {
            let sizeStr = String(l[sizeRange])
            let parts = sizeStr.split(separator: "/")
            if parts.count == 2 {
                downloaded = String(parts[0])
                total = String(parts[1])
            }
        }

        // Extract speed: DL:10MiB
        if let dlRange = l.range(of: #"DL:\d+[\.\d]*[KMG]iB"#, options: .regularExpression) {
            speed = String(l[dlRange]).replacingOccurrences(of: "DL:", with: "") + "/s"
        }

        if !downloaded.isEmpty && !total.isEmpty {
            if !speed.isEmpty {
                return "\(speed)  \(downloaded) / \(total)"
            }
            return "\(downloaded) / \(total)"
        }

        return nil
    }

    private func esc(_ s: String) -> String { s.replacingOccurrences(of: "'", with: "'\\''") }
}

// MARK: - File Size Monitor for firmware download

final class FirmwareDownloadMonitor {
    private let directory: String
    private let expectedTotal: Int64
    private let onProgress: (String) -> Void
    private var timer: DispatchSourceTimer?
    private var prevBytes: Int64 = 0
    private var prevTime = Date()

    init(directory: String, expectedTotal: Int64 = 0, onProgress: @escaping (String) -> Void) {
        self.directory = directory
        self.expectedTotal = expectedTotal
        self.onProgress = onProgress
    }

    func start() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
        t.schedule(deadline: .now() + 1, repeating: 1.0)
        t.setEventHandler { [weak self] in self?.poll() }
        t.resume()
        timer = t
    }

    func stop() { timer?.cancel(); timer = nil }

    private func poll() {
        let fm = FileManager.default

        // Scan directory recursively for all files
        var currentBytes: Int64 = 0
        if let enumerator = fm.enumerator(atPath: directory) {
            while let file = enumerator.nextObject() as? String {
                let path = (directory as NSString).appendingPathComponent(file)
                let size = (try? fm.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
                currentBytes += size
            }
        }

        guard currentBytes > 0 else { return }

        let now = Date()
        let elapsed = now.timeIntervalSince(prevTime)
        var speed: Int64 = 0
        if elapsed > 0.5 {
            speed = max(0, Int64(Double(currentBytes - prevBytes) / elapsed))
            prevBytes = currentBytes
            prevTime = now
        }

        let dlStr = Self.fmt(currentBytes)
        let totalStr = expectedTotal > 0 ? Self.fmt(expectedTotal) : ""
        let speedStr = speed > 0 ? "\(Self.fmt(speed))/s" : ""
        let pct = expectedTotal > 0 ? " (\(Int(Double(currentBytes) / Double(expectedTotal) * 100))%)" : ""

        var parts: [String] = []
        if !speedStr.isEmpty { parts.append(speedStr) }
        if !totalStr.isEmpty {
            parts.append("\(dlStr) / \(totalStr)\(pct)")
        } else {
            parts.append(dlStr)
        }
        onProgress(parts.joined(separator: "  "))
    }

    static func fmt(_ bytes: Int64) -> String {
        if bytes >= 1_073_741_824 {
            return String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
        } else if bytes >= 1_048_576 {
            return String(format: "%.0f MB", Double(bytes) / 1_048_576)
        } else if bytes >= 1024 {
            return String(format: "%.0f KB", Double(bytes) / 1024)
        }
        return "\(bytes) B"
    }
}

// MARK: - Disk size helper (handles sparse files)

func diskActualSize(_ path: String) -> Int64 {
    // stat() returns st_blocks which is actual blocks used (not logical size)
    var st = stat()
    guard stat(path, &st) == 0 else { return 0 }
    return Int64(st.st_blocks) * 512  // st_blocks is in 512-byte units
}
