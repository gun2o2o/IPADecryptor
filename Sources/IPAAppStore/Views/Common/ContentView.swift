import SwiftUI

struct ContentView: View {
    @StateObject private var vm: MainViewModel
    @State private var sidebarSelection: SidebarItem = .setup
    @State private var showConsole = true

    init(vmService: VMService, decryptionService: DecryptionService) {
        _vm = StateObject(wrappedValue: MainViewModel(
            vmService: vmService, decryptionService: decryptionService
        ))
    }

    var body: some View {
        HSplitView {
            NavigationSplitView {
                SidebarView(selection: $sidebarSelection, vm: vm)
            } detail: {
                switch sidebarSelection {
                case .setup: SetupView(vm: vm)
                case .apps: AppListView(vm: vm)
                case .decrypting: DecryptionListView(vm: vm)
                case .library: LibraryView(vm: vm)
                case .settings: SettingsView()
                }
            }
            .navigationSplitViewStyle(.balanced)

            if showConsole {
                LogPanelView(logStore: vm.logStore)
                    .frame(minWidth: 280, idealWidth: 350, maxWidth: 500)
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button(action: { withAnimation { showConsole.toggle() } }) {
                    Image(systemName: showConsole ? "sidebar.right" : "terminal")
                }
                .help(showConsole ? "Hide Console" : "Show Console")
            }
        }
        .alert("Error", isPresented: $vm.showAlert) {
            Button("OK") {}
        } message: { Text(vm.alertMessage ?? "") }
    }
}
