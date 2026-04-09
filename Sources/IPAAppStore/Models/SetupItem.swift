import Foundation

// MARK: - Three main setup groups

enum SetupGroupID: String, CaseIterable, Identifiable {
    case sip = "SIP Disabled"
    case dependencies = "Dependencies"
    case vmSetup = "VM Setup"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .sip: return "lock.open"
        case .dependencies: return "shippingbox"
        case .vmSetup: return "desktopcomputer"
        }
    }
}

enum DepStep: String, CaseIterable {
    case homebrew = "Homebrew"
    case brewPackages = "Brew Packages"
    case vphoneCLI = "vphone-cli"
    case pythonVenv = "frida + pymobiledevice3"
    case vmCreated = "VM Image"
    case firmware = "Firmware Download & Patch"
}

enum VMSetupStep: String, CaseIterable, Identifiable {
    case bootDFU = "DFU Boot"
    case restore = "Firmware Restore"
    case restartDFU = "Restart DFU"
    case ramdiskBuild = "Ramdisk Build"
    case ramdiskSend = "Ramdisk Send"
    case cfwInstall = "CFW Install"
    case fixPasswords = "Fix Passwords"
    case firstBoot = "First Boot (JB Init)"

    var id: String { rawValue }
    var needsSudo: Bool {
        switch self {
        case .ramdiskBuild, .cfwInstall: return true
        default: return false
        }
    }
}

enum StepStatus: Equatable {
    case waiting
    case running(String)
    case needsSudo(String)   // command to run
    case done
    case failed(String)
}

struct VMSetupStepState: Identifiable, Equatable {
    let step: VMSetupStep
    var status: StepStatus = .waiting
    var id: String { step.id }
}

struct SetupGroupState: Identifiable, Equatable {
    let group: SetupGroupID
    var ok: Bool = false
    var installing: Bool = false
    var status: String = ""
    var currentStep: Int = 0
    var totalSteps: Int = 0
    var failedStep: String?
    var errorDetail: String?   // full error message for expandable area
    var expanded: Bool = false  // whether error detail is shown

    var id: String { group.id }

    init(_ group: SetupGroupID) { self.group = group }
}

struct AppSettings {
    enum VPhoneVersion: String, CaseIterable {
        case stable = "Stable (0.1.4 + iOS 26.1)"
        case latest = "Latest"
    }
}
