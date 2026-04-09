import Foundation

enum DecryptionPhase: Equatable {
    case launching
    case dumping(status: String)
    case extracting

    var label: String {
        switch self {
        case .launching: return "Launching app..."
        case .dumping(let s): return s.isEmpty ? "Decrypting..." : s
        case .extracting: return "Extracting IPA..."
        }
    }

    var icon: String {
        switch self {
        case .launching: return "play.circle"
        case .dumping: return "lock.open.rotation"
        case .extracting: return "square.and.arrow.up"
        }
    }
}

enum DecryptionJobState: Equatable {
    case idle
    case active(DecryptionPhase)
    case completed(filePath: String)
    case failed(error: String)

    var isActive: Bool {
        if case .active = self { return true }
        return false
    }
}

struct DecryptionJob: Identifiable, Equatable {
    let id: UUID
    let app: InstalledApp
    var state: DecryptionJobState

    init(app: InstalledApp) {
        self.id = UUID()
        self.app = app
        self.state = .idle
    }
}

enum VMSetupPhase: Equatable {
    case checkingSIP
    case sipDisabled
    case sipEnabled  // blocker
    case checkingDeps
    case installingDeps(status: String)
    case checkingVPhone
    case buildingVPhone(status: String)
    case creatingVM
    case preparingFirmware(status: String)
    case installingFirmware(status: String)
    case bootingVM
    case vmReady
    case error(String)
}

struct VMStatus: Equatable {
    let sipDisabled: Bool
    let vphoneInstalled: Bool
    let vmExists: Bool
    let vmRunning: Bool
    let sshReachable: Bool
    let fridaRunning: Bool

    var isReady: Bool { sipDisabled && vphoneInstalled && vmRunning && sshReachable && fridaRunning }
}
