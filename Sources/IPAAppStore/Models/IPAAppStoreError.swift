import Foundation

enum AppError: LocalizedError, Equatable {
    case sipEnabled
    case shellFailed(String)
    case decryptionFailed(String)
    case sudoRequired(String)
    case appNotFound(String)
    case firmwareFilesNeeded(missing: [String], iphoneURL: String, cloudOSURL: String, targetDir: String)

    var errorDescription: String? {
        switch self {
        case .sipEnabled: return "SIP is enabled. Disable in Recovery Mode."
        case .shellFailed(let m): return m
        case .decryptionFailed(let m): return "Decryption failed: \(m)"
        case .sudoRequired(let cmd): return "Terminal command required:\n\(cmd)"
        case .appNotFound(let m): return "App not found: \(m)"
        case .firmwareFilesNeeded(let missing, _, _, _):
            return "Firmware files needed: \(missing.joined(separator: ", "))"
        }
    }
}
