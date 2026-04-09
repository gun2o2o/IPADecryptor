import SwiftUI

enum SidebarItem: String, Identifiable, CaseIterable {
    case setup = "Setup"
    case apps = "Apps"
    case decrypting = "Decrypting"
    case library = "Library"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .setup: return "gearshape"
        case .apps: return "square.stack.3d.up"
        case .decrypting: return "lock.open.rotation"
        case .library: return "books.vertical"
        case .settings: return "slider.horizontal.3"
        }
    }
}

struct SidebarView: View {
    @Binding var selection: SidebarItem
    @ObservedObject var vm: MainViewModel

    var body: some View {
        List(selection: $selection) {
            Section {
                ForEach([SidebarItem.setup, .apps, .decrypting, .library]) { item in
                    Label {
                        HStack {
                            Text(item.rawValue)
                            Spacer()
                            badge(for: item)
                        }
                    } icon: { Image(systemName: item.icon) }
                    .tag(item)
                }
            }
            Section {
                Label { Text("Settings") } icon: { Image(systemName: "slider.horizontal.3") }
                    .tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 160)
    }

    @ViewBuilder
    private func badge(for item: SidebarItem) -> some View {
        let count: Int = {
            switch item {
            case .decrypting: return vm.activeJobs.count
            case .library: return vm.libraryItems.count
            case .apps: return vm.installedApps.count
            default: return 0
            }
        }()
        if count > 0 {
            Text("\(count)")
                .font(.caption2).fontWeight(.semibold).foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(item == .library ? .green : .blue)
                .clipShape(Capsule())
        }
    }
}
