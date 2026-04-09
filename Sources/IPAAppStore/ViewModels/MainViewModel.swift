import SwiftUI
import AppKit

@MainActor
final class MainViewModel: ObservableObject {
    // Log
    let logStore = LogStore()

    // Setup — 3 groups
    @Published var setupGroups: [SetupGroupState] = SetupGroupID.allCases.map { SetupGroupState($0) }
    @Published var needsWorkspaceSelection = false

    // Sudo dialog
    @Published var showSudoDialog = false
    @Published var sudoCommands: [String] = []
    @Published var sudoDialogTitle = ""
    @Published var sudoContinuation: (() -> Void)?

    // Firmware dialog
    @Published var showFirmwareDialog = false
    @Published var firmwareMissing: [String] = []
    @Published var firmwareIphoneURL = ""
    @Published var selectedIphonePath: String?
    @Published var selectedCloudOSPath: String?
    @Published var firmwareCloudOSURL = ""
    @Published var firmwareTargetDir = ""

    // Apps
    @Published var installedApps: [InstalledApp] = []
    @Published var isLoadingApps = false

    // Decryption
    @Published var jobs: [DecryptionJob] = []

    // Alert
    @Published var alertMessage: String?
    @Published var showAlert = false

    let vmService: VMService
    private let decryptionService: DecryptionService

    var allSetupOK: Bool { setupGroups.allSatisfy { $0.ok } }
    var depsOK: Bool { setupGroups.first(where: { $0.group == .dependencies })?.ok ?? false }
    var vmSetupOK: Bool { setupGroups.first(where: { $0.group == .vmSetup })?.ok ?? false }

    var libraryItems: [DecryptionJob] {
        jobs.filter { if case .completed = $0.state { return true }; return false }
    }
    var activeJobs: [DecryptionJob] {
        jobs.filter { $0.state.isActive }
    }

    init(vmService: VMService, decryptionService: DecryptionService) {
        self.vmService = vmService
        self.decryptionService = decryptionService
        vmService.logStore = logStore
        if vmService.workspacePath.isEmpty { needsWorkspaceSelection = true }
    }

    // MARK: - Workspace

    func selectWorkspace() {
        let panel = NSOpenPanel()
        panel.title = "Select Workspace Directory"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            vmService.workspacePath = url.path
            try? FileManager.default.createDirectory(atPath: vmService.ipaOutputDir, withIntermediateDirectories: true)
            needsWorkspaceSelection = false
            refreshAllChecks()
        }
    }

    func resetWorkspace() {
        do {
            try vmService.resetWorkspace()
            for i in setupGroups.indices {
                setupGroups[i].ok = false
                setupGroups[i].status = ""
                setupGroups[i].failedStep = nil
                setupGroups[i].currentStep = 0
            }
            installedApps = []
            jobs = []
        } catch {
            showError("Reset failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Checks

    func refreshAllChecks() {
        Task {
            // SIP
            let sipOK = await vmService.checkSIP()
            updateGroup(.sip) { $0.ok = sipOK }

            // Dependencies
            let (depOK, depFailed) = await vmService.checkDependencies()
            updateGroup(.dependencies) { $0.ok = depOK; $0.failedStep = depFailed }

            // VM Setup
            let (vmOK, vmFailed) = await vmService.checkVMSetup()
            updateGroup(.vmSetup) { $0.ok = vmOK; $0.failedStep = vmFailed }
        }
    }

    // MARK: - Fix Dependencies

    func fixDependencies() {
        guard !groupState(.dependencies).installing else { return }
        updateGroup(.dependencies) { $0.installing = true; $0.failedStep = nil }

        Task {
            do {
                try await vmService.fixDependencies { [weak self] step, total, name, status in
                    Task { @MainActor in
                        self?.updateGroup(.dependencies) {
                            $0.currentStep = step
                            $0.totalSteps = total
                            $0.status = "\(name): \(status)"
                        }
                    }
                }
                let (ok, failed) = await vmService.checkDependencies()
                updateGroup(.dependencies) { $0.ok = ok; $0.installing = false; $0.failedStep = failed; $0.status = ok ? "All done" : "" }
            } catch let error as AppError {
                if case .sudoRequired(let cmd) = error {
                    updateGroup(.dependencies) { $0.installing = false; $0.status = "Requires terminal command" }
                    showSudoCommand(title: "Sudo Required", commands: [cmd]) { [weak self] in
                        self?.refreshAllChecks()
                    }
                } else if case .firmwareFilesNeeded(let missing, let iphoneURL, let cloudOSURL, let targetDir) = error {
                    updateGroup(.dependencies) { $0.installing = false; $0.status = "Firmware files needed" }
                    showFirmwareDialog(missing: missing, iphoneURL: iphoneURL, cloudOSURL: cloudOSURL, targetDir: targetDir)
                } else {
                    updateGroup(.dependencies) {
                        $0.installing = false
                        $0.errorDetail = error.localizedDescription
                        $0.expanded = true
                        $0.status = ""
                    }
                }
            } catch {
                updateGroup(.dependencies) {
                    $0.installing = false
                    $0.errorDetail = error.localizedDescription
                    $0.expanded = true
                    $0.status = ""
                }
            }
        }
    }

    // MARK: - Fix VM Setup (hybrid: auto + sudo pause)

    @Published var vmSetupSteps: [VMSetupStepState] = VMSetupStep.allCases.map { VMSetupStepState(step: $0) }
    @Published var vmSetupRunning = false

    // Sudo step continuation
    private var sudoStepContinuation: CheckedContinuation<Void, Never>?

    func fixVMSetup() {
        guard !vmSetupRunning else { return }
        vmSetupRunning = true
        vmSetupSteps = VMSetupStep.allCases.map { VMSetupStepState(step: $0) }
        updateGroup(.vmSetup) { $0.installing = true; $0.errorDetail = nil }

        // Wire up sudo callback
        vmService.onSudoNeeded = { [weak self] step, command in
            await self?.waitForSudoStep(step: step, command: command)
        }

        Task {
            do {
                try await vmService.runVMSetup { [weak self] step, status in
                    Task { @MainActor in
                        self?.updateVMStep(step, status: status)
                        // Also update group status text
                        if case .running(let msg) = status {
                            self?.updateGroup(.vmSetup) { $0.status = "\(step.rawValue): \(msg)" }
                        }
                    }
                }
                updateGroup(.vmSetup) { $0.ok = true; $0.installing = false; $0.status = "Complete" }
            } catch {
                updateGroup(.vmSetup) {
                    $0.installing = false; $0.errorDetail = error.localizedDescription; $0.expanded = true
                }
            }
            vmSetupRunning = false
            refreshAllChecks()
        }
    }

    private func waitForSudoStep(step: VMSetupStep, command: String) async {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                self.sudoStepContinuation = continuation
                self.showSudoCommand(title: "\(step.rawValue) — Terminal Required", commands: [command]) { [weak self] in
                    self?.sudoStepContinuation?.resume()
                    self?.sudoStepContinuation = nil
                }
            }
        }
    }

    private func updateVMStep(_ step: VMSetupStep, status: StepStatus) {
        if let i = vmSetupSteps.firstIndex(where: { $0.step == step }) {
            vmSetupSteps[i].status = status
        }
    }

    // MARK: - Launch VM

    @Published var isLaunching = false

    func launchVM() {
        guard !isLaunching else { return }
        isLaunching = true
        Task {
            do {
                try await vmService.launchVM { [weak self] status in
                    Task { @MainActor in
                        self?.updateGroup(.vmSetup) { $0.status = status }
                    }
                }
            } catch {
                showError(error.localizedDescription)
            }
            isLaunching = false
            refreshAllChecks()
        }
    }

    // MARK: - Firmware Files

    func showFirmwareDialog(missing: [String], iphoneURL: String, cloudOSURL: String, targetDir: String) {
        firmwareMissing = missing
        firmwareIphoneURL = iphoneURL
        firmwareCloudOSURL = cloudOSURL
        firmwareTargetDir = targetDir
        showFirmwareDialog = true
    }

    func importiPhoneIPSW() {
        guard let path = pickFile(title: "Select iPhone IPSW") else { return }
        selectedIphonePath = path
        vmService.iphoneIPSWPath = path
    }

    func importCloudOSIPSW() {
        guard let path = pickFile(title: "Select cloudOS IPSW") else { return }
        selectedCloudOSPath = path
        vmService.cloudOSIPSWPath = path
    }

    func confirmFirmwareImport() {
        showFirmwareDialog = false
        fixDependencies()
    }

    private func pickFile(title: String) -> String? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.prompt = "Select"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return url.path
    }

    // MARK: - Apps

    func refreshApps() {
        isLoadingApps = true
        Task {
            do { installedApps = try await vmService.listInstalledApps() }
            catch { print("[Apps] \(error)") }
            isLoadingApps = false
        }
    }

    // MARK: - Decrypt

    func decryptApp(_ app: InstalledApp) {
        if jobs.contains(where: { $0.app.bundleId == app.bundleId && $0.state.isActive }) { return }
        var job = DecryptionJob(app: app)
        job.state = .active(.launching)
        jobs.insert(job, at: 0)
        let jid = job.id
        Task {
            do {
                let path = try await decryptionService.decrypt(app: app, outputDir: vmService.ipaOutputDir) { [weak self] phase in
                    Task { @MainActor in self?.updateJob(jid, state: .active(phase)) }
                }
                updateJob(jid, state: .completed(filePath: path))
            } catch {
                updateJob(jid, state: .failed(error: error.localizedDescription))
            }
        }
    }

    // MARK: - Actions

    func openVNC() { vmService.openVNC() }
    func revealInFinder(path: String) { NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "") }
    func removeJob(id: UUID) { jobs.removeAll { $0.id == id } }

    // MARK: - Sudo Dialog

    private func showSudoCommand(title: String, commands: [String], onDone: @escaping () -> Void) {
        sudoDialogTitle = title
        sudoCommands = commands
        sudoContinuation = onDone
        showSudoDialog = true
    }

    func dismissSudoDialog() {
        showSudoDialog = false
        sudoContinuation?()
        sudoContinuation = nil
    }

    // MARK: - Helpers

    private func groupState(_ g: SetupGroupID) -> SetupGroupState {
        setupGroups.first(where: { $0.group == g }) ?? SetupGroupState(g)
    }

    private func updateGroup(_ g: SetupGroupID, _ body: (inout SetupGroupState) -> Void) {
        if let i = setupGroups.firstIndex(where: { $0.group == g }) { body(&setupGroups[i]) }
    }

    private func updateJob(_ id: UUID, state: DecryptionJobState) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].state = state }
    }

    private func showError(_ msg: String) { alertMessage = msg; showAlert = true }
}
