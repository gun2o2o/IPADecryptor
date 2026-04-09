import SwiftUI

struct AppListView: View {
    @ObservedObject var vm: MainViewModel

    private var sshOK: Bool {
        vm.setupGroups.first(where: { $0.group == .vmSetup })?.ok ?? false
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Apps on Virtual iPhone").font(.headline)
                Spacer()
                if vm.isLoadingApps { ProgressView().controlSize(.small) }
                Button(action: { vm.refreshApps() }) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }.buttonStyle(.bordered).controlSize(.small)
            }
            .padding(.horizontal, 16).padding(.vertical, 10).background(.bar)

            // Info banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle.fill").foregroundStyle(.blue)
                Text("Install apps via the App Store in VNC. The app must be launched at least once before decryption.")
                    .font(.caption)
            }
            .padding(.horizontal, 16).padding(.vertical, 8)
            .background(.blue.opacity(0.05))

            Divider()

            if !sshOK {
                VStack(spacing: 12) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("VM not connected").font(.headline).foregroundStyle(.secondary)
                    Text("Complete all items in the Setup tab first.")
                        .font(.subheadline).foregroundStyle(.tertiary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.installedApps.isEmpty && !vm.isLoadingApps {
                VStack(spacing: 12) {
                    Image(systemName: "square.stack.3d.up")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No apps found").font(.headline).foregroundStyle(.secondary)
                    Text("Open VNC, sign into the App Store,\nand download some apps.")
                        .font(.subheadline).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    Button("Open VNC") { vm.openVNC() }
                        .buttonStyle(.borderedProminent)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(vm.installedApps) { app in
                    AppListItemView(app: app) { vm.decryptApp(app) }
                }.listStyle(.inset)
            }
        }
        .onAppear { if sshOK { vm.refreshApps() } }
    }
}
