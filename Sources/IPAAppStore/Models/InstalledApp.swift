import Foundation

struct InstalledApp: Identifiable, Hashable {
    let bundleId: String
    let name: String
    let version: String
    let path: String  // path on VM

    var id: String { bundleId }
}
