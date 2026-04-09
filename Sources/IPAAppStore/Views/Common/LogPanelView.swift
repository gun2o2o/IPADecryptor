import SwiftUI

struct LogPanelView: View {
    @ObservedObject var logStore: LogStore

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(logStore.tabs) { tab in
                        tabButton(tab)
                    }
                    Spacer()
                }
            }
            .frame(height: 28)
            .background(Color(white: 0.15))

            Divider()

            // Log content
            if let tabId = logStore.activeTabId,
               let tab = logStore.tabs.first(where: { $0.id == tabId }) {
                logContent(tab)
            } else {
                VStack {
                    Text("No active process")
                        .font(.caption).foregroundStyle(.gray)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black)
            }
        }
        .frame(minWidth: 280)
    }

    private func tabButton(_ tab: LogStore.LogTab) -> some View {
        let isActive = logStore.activeTabId == tab.id
        return HStack(spacing: 4) {
            if tab.isActive {
                Circle().fill(.green).frame(width: 6, height: 6)
            }
            Text(tab.name)
                .font(.caption2)
                .foregroundStyle(isActive ? .white : .gray)
            if !tab.isActive {
                Button(action: { logStore.removeTab(tab.id) }) {
                    Image(systemName: "xmark").font(.system(size: 8))
                }
                .buttonStyle(.plain).foregroundStyle(.gray)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isActive ? Color(white: 0.25) : Color.clear)
        .onTapGesture { logStore.activeTabId = tab.id }
    }

    private func logContent(_ tab: LogStore.LogTab) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(tab.lines) { line in
                        Text(line.text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(line.isError ? .red : .white.opacity(0.9))
                            .textSelection(.enabled)
                            .id(line.id)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: tab.lines.count) { _ in
                if let last = tab.lines.last {
                    withAnimation(.none) { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .background(.black)
    }
}
