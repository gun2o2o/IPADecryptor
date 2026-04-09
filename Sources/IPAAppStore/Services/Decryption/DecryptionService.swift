import Foundation
import SwiftUI

/// Decrypts an app installed on the vphone VM using frida-ios-dump.
/// Assumes: VM is running, SSH reachable, frida-server active, app is installed.
final class DecryptionService {
    private let vmService: VMService

    private var fridaDumpDir: String { vmService.fridaDumpDir }

    @AppStorage("sshPort") private var sshPort = "2222"
    @AppStorage("sshPassword") private var sshPassword = "alpine"

    init(vmService: VMService) {
        self.vmService = vmService
    }

    /// Decrypt an app: launch → frida dump → extract IPA to Mac.
    func decrypt(
        app: InstalledApp,
        outputDir: String,
        onPhase: @escaping (DecryptionPhase) -> Void
    ) async throws -> String {
        // 1. Launch app in VM
        onPhase(.launching)
        try await vmService.launchApp(bundleId: app.bundleId)
        try await Task.sleep(nanoseconds: 5_000_000_000)

        // 2. Run frida-ios-dump on Mac (connects to VM's frida-server)
        onPhase(.dumping(status: "Starting frida-ios-dump..."))
        let dumpScript = fridaDumpDir + "/dump.py"

        guard FileManager.default.fileExists(atPath: dumpScript) else {
            throw AppError.decryptionFailed("frida-ios-dump not found.\nRun: git clone https://github.com/AloneMonkey/frida-ios-dump ~/frida-ios-dump")
        }

        // Configure dump.py SSH connection via env or edit config
        // frida-ios-dump reads SSH config from dump.py itself. We need to ensure
        // it connects to the right port. Pass as env vars if supported,
        // otherwise fall back to default (localhost:2222)

        let venvPython = vmService.venvDir + "/bin/python3"
        let pythonExe = FileManager.default.fileExists(atPath: venvPython) ? venvPython : "/usr/bin/python3"

        let (dumpOut, dumpErr, dumpExit) = try await shellWithProgress(
            pythonExe,
            args: [dumpScript, app.bundleId],
            workDir: fridaDumpDir
        ) { line in
            let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                print("[frida] \(t)")
                onPhase(.dumping(status: t))
            }
        }

        print("[frida] exit=\(dumpExit) out=\(dumpOut.prefix(300))")
        if dumpExit != 0 { print("[frida] err=\(dumpErr.prefix(300))") }

        // 3. Find and move the decrypted IPA
        onPhase(.extracting)
        let san = app.name.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_")
        let finalPath = (outputDir as NSString).appendingPathComponent("\(san)_decrypted.ipa")

        // frida-ios-dump saves to its working directory
        if let files = try? FileManager.default.contentsOfDirectory(atPath: fridaDumpDir) {
            if let ipa = files.first(where: { $0.hasSuffix(".ipa") }) {
                let src = (fridaDumpDir as NSString).appendingPathComponent(ipa)
                try? FileManager.default.removeItem(atPath: finalPath)
                try FileManager.default.moveItem(atPath: src, toPath: finalPath)
                return finalPath
            }
        }

        throw AppError.decryptionFailed("Decrypted IPA not found.\n\(dumpOut.prefix(200))\n\(dumpErr.prefix(200))")
    }

    // MARK: - Shell

    private func shellWithProgress(
        _ exe: String, args: [String], workDir: String? = nil,
        onLine: @escaping (String) -> Void
    ) async throws -> (String, String, Int32) {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global().async {
                let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
                if let w = workDir { p.currentDirectoryURL = URL(fileURLWithPath: w) }
                let op = Pipe(), ep = Pipe(); p.standardOutput = op; p.standardError = ep
                var env = ProcessInfo.processInfo.environment; env["HOME"] = NSHomeDirectory()
                env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (env["PATH"] ?? "")
                p.environment = env
                var ao = Data(), ae = Data()
                op.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; guard !d.isEmpty else{return}; ao.append(d); if let t=String(data:d,encoding:.utf8){for l in t.components(separatedBy:.newlines){onLine(l)}} }
                ep.fileHandleForReading.readabilityHandler = { h in let d = h.availableData; guard !d.isEmpty else{return}; ae.append(d); if let t=String(data:d,encoding:.utf8){for l in t.components(separatedBy:.newlines){onLine(l)}} }
                do {
                    try p.run(); p.waitUntilExit()
                    op.fileHandleForReading.readabilityHandler = nil; ep.fileHandleForReading.readabilityHandler = nil
                    ao.append(op.fileHandleForReading.readDataToEndOfFile()); ae.append(ep.fileHandleForReading.readDataToEndOfFile())
                    cont.resume(returning: (String(data:ao,encoding:.utf8) ?? "", String(data:ae,encoding:.utf8) ?? "", p.terminationStatus))
                } catch { cont.resume(throwing: error) }
            }
        }
    }
}
