import SwiftUI

@main
struct IPAAppStoreApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    private let vmService: VMService
    private let decryptionService: DecryptionService

    init() {
        let vm = VMService()
        self.vmService = vm
        self.decryptionService = DecryptionService(vmService: vm)
        appDelegate.vmService = vm
    }

    var body: some Scene {
        WindowGroup {
            ContentView(vmService: vmService, decryptionService: decryptionService)
                .frame(minWidth: 700, minHeight: 500)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 600)

        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var vmService: VMService?

    func applicationWillTerminate(_ notification: Notification) {
        vmService?.terminateAll()
    }
}
