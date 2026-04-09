import SwiftUI
import AppKit

struct SetupView: View {
    @ObservedObject var vm: MainViewModel

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Setup").font(.headline)
                Spacer()
                Text(vm.vmService.workspacePath)
                    .font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                Button("Change") { vm.selectWorkspace() }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(.blue)
                Button(action: { vm.refreshAllChecks() }) {
                    Image(systemName: "arrow.clockwise")
                }.buttonStyle(.plain).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)
            Divider()

            if vm.needsWorkspaceSelection {
                workspaceSelector
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        sipRow
                        depsRow
                        vmSetupRow

                        Divider().padding(.vertical, 4)

                        if vm.allSetupOK {
                            readySection
                            launchSection
                        } else if vm.depsOK {
                            launchSection
                        }

                        resetSection
                    }
                    .padding(16)
                }
            }
        }
        .onAppear { if !vm.needsWorkspaceSelection { vm.refreshAllChecks() } }
        .sheet(isPresented: $vm.showSudoDialog) { sudoDialog }
        .sheet(isPresented: $vm.showFirmwareDialog) { firmwareDialog }
        .sheet(item: $activeInfoGroup) { group in
            infoDialogFor(group)
        }
    }

    // MARK: - Workspace

    private var workspaceSelector: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 48)).foregroundStyle(.blue)
            Text("Select Workspace Directory")
                .font(.title3).fontWeight(.semibold)
            Text("All tools and decrypted IPAs will be stored here.\nNeeds ~80GB free space.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button("Choose Directory") { vm.selectWorkspace() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - SIP

    private var sipRow: some View {
        let state = vm.setupGroups.first(where: { $0.group == .sip })!
        return setupGroupRow(state: state, action: nil, infoAction: { showInfo(for: .sip) })
    }

    // MARK: - Dependencies

    private var depsRow: some View {
        let state = vm.setupGroups.first(where: { $0.group == .dependencies })!
        return setupGroupRow(state: state, action: { vm.fixDependencies() }, infoAction: { showInfo(for: .dependencies) })
    }

    // MARK: - VM Setup

    private var vmSetupRow: some View {
        let state = vm.setupGroups.first(where: { $0.group == .vmSetup })!
        return VStack(alignment: .leading, spacing: 0) {
            setupGroupRow(state: state, action: !vm.depsOK || state.ok ? nil : { vm.fixVMSetup() }, infoAction: { showInfo(for: .vmSetup) })

            // Show sub-steps when running or has run
            if vm.vmSetupRunning || vm.vmSetupSteps.contains(where: { if case .done = $0.status { return true }; return false }) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(vm.vmSetupSteps) { stepState in
                        vmStepRow(stepState)
                    }
                }
                .padding(.leading, 50)
                .padding(.vertical, 6)
            }
        }
    }

    private func vmStepRow(_ s: VMSetupStepState) -> some View {
        HStack(spacing: 8) {
            switch s.status {
            case .waiting:
                Image(systemName: "circle").foregroundStyle(.tertiary).frame(width: 14)
            case .running:
                ProgressView().controlSize(.mini).frame(width: 14)
            case .needsSudo:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).frame(width: 14)
            case .done:
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).frame(width: 14)
            case .failed:
                Image(systemName: "xmark.circle.fill").foregroundStyle(.red).frame(width: 14)
            }

            Text(s.step.rawValue).font(.caption)

            switch s.status {
            case .running(let msg):
                Text(msg).font(.caption2).foregroundStyle(.blue)
            case .needsSudo:
                Text("Terminal required").font(.caption2).foregroundStyle(.orange)
            case .failed(let err):
                Text(err).font(.caption2).foregroundStyle(.red).lineLimit(1)
            default:
                EmptyView()
            }

            Spacer()
        }
    }

    // MARK: - Bottom

    private var readySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("All set!", systemImage: "checkmark.seal.fill")
                .font(.headline).foregroundStyle(.green)
        }
    }

    private var launchSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button("Launch VM") { vm.launchVM() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.isLaunching || vm.vmSetupRunning)

                Button("Refresh Status") { vm.refreshAllChecks() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            if vm.isLaunching {
                let vmState = vm.setupGroups.first(where: { $0.group == .vmSetup })
                HStack {
                    ProgressView().controlSize(.small)
                    Text(vmState?.status ?? "Launching...").font(.subheadline).foregroundStyle(.blue)
                }
            }

            Divider().padding(.vertical, 4)

            // Setup guide
            VStack(alignment: .leading, spacing: 10) {
                Text("After VM boots:").font(.subheadline).fontWeight(.semibold)

                guideStep(1, "iOS Initial Setup",
                    "Select language/region (do NOT select Japan or EU).\nSkip Apple ID during setup if it fails — sign in later in Settings.")

                guideStep(2, "Sign in to Apple ID",
                    "Settings → Apple ID → Sign in.\nIf 'Unknown error' appears, skip and try again later.\nSome accounts may need to be signed in on a real device first.")

                guideStep(3, "Install OpenSSH (Sileo)",
                    "Open Sileo → Search 'openssh' → Install → Respring.")

                guideStep(4, "Install frida-server (Sileo)",
                    "Sileo → Sources → Add: https://build.frida.re/\nSearch 're.frida.server' → Install.")

                guideStep(5, "Download Apps (App Store)",
                    "Open App Store → Download the apps you want to decrypt.")

                guideStep(6, "Decrypt",
                    "Come back here → Apps tab → Refresh → Select app → Decrypt.")
            }
            .padding(12)
            .background(.blue.opacity(0.03))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
    }

    private func guideStep(_ num: Int, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("\(num)")
                .font(.caption).fontWeight(.bold)
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(.blue)
                .clipShape(Circle())
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).fontWeight(.semibold)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
    }

    private var resetSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider().padding(.vertical, 4)
            Button(role: .destructive) { vm.resetWorkspace() } label: {
                Label("Reset Workspace", systemImage: "trash")
            }
            .buttonStyle(.plain).foregroundStyle(.red).font(.caption)
            Text("Deletes all tools and data in the workspace.")
                .font(.caption2).foregroundStyle(.tertiary)
        }
    }

    // MARK: - Expandable Group Row

    @State private var activeInfoGroup: SetupGroupID?

    private func showInfo(for group: SetupGroupID) {
        activeInfoGroup = group
    }

    private func manualCommands(for group: SetupGroupID) -> [String] {
        let dir = vm.vmService.vphoneDir
        let venv = vm.vmService.venvDir
        switch group {
        case .sip:
            return [
                "# Disable SIP (System Integrity Protection)",
                "# 1. Shut down your Mac",
                "# 2. Press and hold the Power button until 'Loading startup options' appears",
                "# 3. Select Options → Continue",
                "# 4. Open Terminal from the menu bar (Utilities → Terminal)",
                "# 5. Run:",
                "csrutil disable",
                "",
                "# 6. Also enable research guests:",
                "csrutil allow-research-guests enable",
                "",
                "# 7. Reboot:",
                "reboot",
                "",
                "# 8. After reboot, set AMFI boot-arg:",
                "sudo nvram boot-args=\"amfi_get_out_of_my_way=1 -v\"",
                "",
                "# 9. Reboot again for boot-arg to take effect",
            ]
        case .dependencies:
            return [
                "# Step 1: Install Homebrew",
                "/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\"",
                "",
                "# Step 2: Install Python 3.12",
                "brew install python@3.12",
                "",
                "# Step 3: Install required packages",
                "brew install aria2 wget gnu-tar openssl@3 ldid-procursus sshpass keystone libusb ipsw zstd autoconf automake pkg-config cmake libtool libimobiledevice ideviceinstaller",
                "",
                "# Step 4: Clone and build vphone-cli",
                "git clone --recurse-submodules -b 0.1.4 https://github.com/Lakr233/vphone-cli.git \(dir)",
                "cd \(dir) && make setup_tools && make build",
                "",
                "# Step 5: Install frida + pymobiledevice3 into vphone venv",
                "\(venv)/bin/pip3 install frida-tools pymobiledevice3",
                "",
                "# Step 6: Clone frida-ios-dump",
                "git clone --depth=1 https://github.com/AloneMonkey/frida-ios-dump.git \(vm.vmService.fridaDumpDir)",
                "\(venv)/bin/pip3 install -r \(vm.vmService.fridaDumpDir)/requirements.txt",
                "",
                "# Step 7: Create VM",
                "cd \(dir) && make vm_new CPU=4 MEMORY=4096 DISK_SIZE=64",
                "",
                "# Step 8: Download firmware (select iPhone IPSW + cloudOS IPSW files)",
                "cd \(dir) && make fw_prepare IPHONE_SOURCE=/path/to/iPhone.ipsw CLOUDOS_SOURCE=/path/to/cloudOS.ipsw",
                "",
                "# Step 9: Patch firmware",
                "cd \(dir) && make fw_patch_jb",
            ]
        case .vmSetup:
            return [
                "# Step 1: Boot DFU (Terminal 1 — keep running)",
                "cd \(dir) && make boot_dfu",
                "",
                "# Step 2: Restore firmware (Terminal 2)",
                "cd \(dir) && source \(venv)/bin/activate && make restore_get_shsh && make restore",
                "",
                "# Step 3: Ctrl+C Terminal 1, restart DFU",
                "cd \(dir) && make boot_dfu",
                "",
                "# Step 4: Build ramdisk (requires sudo)",
                "cd \(dir) && sudo env PATH=\"$PATH:/opt/homebrew/bin\" make ramdisk_build",
                "",
                "# Step 5: Send ramdisk (Terminal 2)",
                "cd \(dir) && source \(venv)/bin/activate && make ramdisk_send",
                "",
                "# Step 6: Set Xcode SDK (requires sudo)",
                "sudo xcode-select -s /Applications/Xcode.app/Contents/Developer",
                "",
                "# Step 7: Install CFW (Terminal 3, while DFU + ramdisk are running)",
                "cd \(dir) && make cfw_install_jb",
                "",
                "# Step 8: Boot VM",
                "cd \(dir) && make boot",
                "",
                "# Step 9: SSH port forward (Terminal 2)",
                "cd \(dir) && source \(venv)/bin/activate && python3 -m pymobiledevice3 usbmux forward 2222 22",
            ]
        }
    }

    private func setupGroupRow(state: SetupGroupState, action: (() -> Void)? = nil, infoAction: (() -> Void)? = nil) -> some View {
        let hasError = state.errorDetail != nil && !state.ok

        return VStack(alignment: .leading, spacing: 0) {
            // Main row
            HStack(spacing: 10) {
                if state.installing {
                    ProgressView().controlSize(.small).frame(width: 20)
                } else {
                    Image(systemName: state.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(state.ok ? .green : .red).frame(width: 20)
                }

                Image(systemName: state.group.icon).foregroundStyle(.secondary).frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(state.group.rawValue).font(.body)
                        if state.installing && state.totalSteps > 0 {
                            Text("(\(state.currentStep)/\(state.totalSteps))")
                                .font(.caption).foregroundStyle(.blue)
                        }
                    }
                    if state.installing && !state.status.isEmpty {
                        Text(state.status).font(.caption2).foregroundStyle(.blue)
                    } else if let failed = state.failedStep, !state.ok, !state.installing {
                        Text("Stopped at: \(failed)").font(.caption2).foregroundStyle(.orange)
                    } else if !state.ok && !state.installing && state.errorDetail == nil {
                        Text(helpText(for: state.group)).font(.caption2).foregroundStyle(.secondary)
                    }
                }

                Spacer()

                // Info button
                if let infoAction = infoAction {
                    Button(action: infoAction) {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain).controlSize(.small)
                    .help("Manual setup instructions")
                }

                if hasError {
                    Button { toggleExpanded(state.group) } label: {
                        Image(systemName: state.expanded ? "chevron.up" : "chevron.down")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }

                if let action = action, !state.ok, !state.installing {
                    Button("Fix", action: action)
                        .buttonStyle(.bordered).controlSize(.small)
                }
            }
            .padding(.vertical, 6)

            // Expandable error detail
            if hasError && state.expanded {
                VStack(alignment: .leading, spacing: 8) {
                    Text(state.errorDetail ?? "")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.06))
                        .clipShape(RoundedRectangle(cornerRadius: 6))

                    if let action = action {
                        Button("Retry") { action() }
                            .buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .padding(.leading, 50)
                .padding(.bottom, 6)
            }
        }
    }

    private func toggleExpanded(_ group: SetupGroupID) {
        if let i = vm.setupGroups.firstIndex(where: { $0.group == group }) {
            vm.setupGroups[i].expanded.toggle()
        }
    }

    private func helpText(for group: SetupGroupID) -> String {
        switch group {
        case .sip: return "Restart → Hold Power → Terminal → csrutil disable"
        case .dependencies: return "Homebrew, packages, Python, vphone-cli, VM, firmware"
        case .vmSetup: return "Firmware install, boot, SSH, frida"
        }
    }

    private func fileSizeLabel(_ path: String?) -> String {
        guard let path = path else { return "" }
        let size = (try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? Int64 ?? 0
        guard size > 0 else { return "" }
        return " (\(FirmwareDownloadMonitor.fmt(size)))"
    }

    // MARK: - Sudo Dialog

    private var sudoDialog: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 36)).foregroundStyle(.orange)
            Text(vm.sudoDialogTitle)
                .font(.title3).fontWeight(.semibold)
            Text("Run the following commands in Terminal:")
                .font(.subheadline).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(vm.sudoCommands, id: \.self) { line in
                        if line.isEmpty {
                            Spacer().frame(height: 8)
                        } else if line.hasPrefix("#") {
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(4)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 250)

            Button("Copy All Commands") {
                let text = vm.sudoCommands.filter { !$0.isEmpty && !$0.hasPrefix("#") }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.bordered)

            Text("After running the commands, press Done.")
                .font(.caption).foregroundStyle(.secondary)

            Button("Done") { vm.dismissSudoDialog() }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
        .padding(24)
        .frame(width: 500, height: 450)
    }

    // MARK: - Firmware Dialog

    private var firmwareDialog: some View {
        VStack(spacing: 16) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 36)).foregroundStyle(.blue)
            Text("Firmware Files Required")
                .font(.title3).fontWeight(.semibold)
            Text("Download in Safari, then select each file below.")
                .font(.subheadline).foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 16) {
                // iPhone IPSW
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: vm.selectedIphonePath != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vm.selectedIphonePath != nil ? .green : .secondary)
                        Text("iPhone IPSW" + fileSizeLabel(vm.selectedIphonePath)).font(.body).fontWeight(.medium)
                    }
                    Text(vm.firmwareIphoneURL)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).foregroundStyle(.blue).lineLimit(1)
                    HStack(spacing: 8) {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vm.firmwareIphoneURL, forType: .string)
                        }.buttonStyle(.bordered).controlSize(.mini)
                        Button("Select File") { vm.importiPhoneIPSW() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        if let path = vm.selectedIphonePath {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.caption2).foregroundStyle(.green).lineLimit(1)
                        }
                    }
                }

                Divider()

                // cloudOS IPSW
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: vm.selectedCloudOSPath != nil ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(vm.selectedCloudOSPath != nil ? .green : .secondary)
                        Text("cloudOS IPSW" + fileSizeLabel(vm.selectedCloudOSPath)).font(.body).fontWeight(.medium)
                    }
                    Text(vm.firmwareCloudOSURL)
                        .font(.system(.caption2, design: .monospaced))
                        .textSelection(.enabled).foregroundStyle(.blue).lineLimit(1)
                    HStack(spacing: 8) {
                        Button("Copy URL") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(vm.firmwareCloudOSURL, forType: .string)
                        }.buttonStyle(.bordered).controlSize(.mini)
                        Button("Select File") { vm.importCloudOSIPSW() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        if let path = vm.selectedCloudOSPath {
                            Text(URL(fileURLWithPath: path).lastPathComponent)
                                .font(.caption2).foregroundStyle(.green).lineLimit(1)
                        }
                    }
                }
            }
            .padding(12)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            HStack(spacing: 12) {
                Button("Cancel") { vm.showFirmwareDialog = false }
                    .buttonStyle(.bordered)
                Button("Continue") { vm.confirmFirmwareImport() }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.selectedIphonePath == nil || vm.selectedCloudOSPath == nil)
            }
        }
        .padding(24)
        .frame(width: 560, height: 420)
    }

    // MARK: - Info Dialog

    private func infoDialogFor(_ group: SetupGroupID) -> some View {
        let commands = manualCommands(for: group)
        return VStack(spacing: 16) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 36)).foregroundStyle(.blue)
            Text(group.rawValue + " — Manual Setup")
                .font(.title3).fontWeight(.semibold)
            Text("You can run these commands manually in Terminal:")
                .font(.subheadline).foregroundStyle(.secondary)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(commands.enumerated()), id: \.offset) { _, line in
                        if line.isEmpty {
                            Spacer().frame(height: 8)
                        } else if line.hasPrefix("#") {
                            Text(line).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .padding(4)
                                .background(.quaternary)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 300)

            Button("Copy All Commands") {
                let text = commands.filter { !$0.isEmpty && !$0.hasPrefix("#") }.joined(separator: "\n")
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            .buttonStyle(.bordered)

            Button("Close") { activeInfoGroup = nil }
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(width: 560, height: 500)
    }
}
