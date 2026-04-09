import Foundation

/// Thread-safe multi-tab log store.
@MainActor
final class LogStore: ObservableObject {
    @Published var tabs: [LogTab] = []
    @Published var activeTabId: UUID?

    private let maxLines = 3000

    struct LogLine: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    struct LogTab: Identifiable {
        let id = UUID()
        let name: String
        var lines: [LogLine] = []
        var isActive: Bool = true
    }

    /// Create a new tab and return its ID
    func createTab(name: String) -> UUID {
        let tab = LogTab(name: name)
        tabs.append(tab)
        if activeTabId == nil { activeTabId = tab.id }
        return tab.id
    }

    /// Append log to a specific tab
    func append(to tabId: UUID, _ text: String, isError: Bool = false) {
        guard let i = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let cleaned = text.replacingOccurrences(of: #"\x1B\[[0-9;]*[a-zA-Z]"#, with: "", options: .regularExpression)
        for line in cleaned.components(separatedBy: CharacterSet.newlines.union(.init(charactersIn: "\r"))) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            tabs[i].lines.append(LogLine(text: trimmed, isError: isError))
        }
        if tabs[i].lines.count > maxLines {
            tabs[i].lines.removeFirst(tabs[i].lines.count - maxLines)
        }
    }

    /// Mark tab as finished. Auto-removes after 3 seconds if no errors.
    func finishTab(_ tabId: UUID) {
        guard let i = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[i].isActive = false

        // Auto-remove if no errors (let error tabs stay for debugging)
        let hasErrors = tabs[i].lines.contains { $0.isError }
        if !hasErrors {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_000_000_000)
                self.removeTab(tabId)
            }
        }
    }

    /// Remove a finished tab
    func removeTab(_ tabId: UUID) {
        tabs.removeAll { $0.id == tabId }
        if activeTabId == tabId { activeTabId = tabs.first?.id }
    }

    /// Remove all finished tabs
    func cleanFinished() {
        tabs.removeAll { !$0.isActive }
        if let active = activeTabId, !tabs.contains(where: { $0.id == active }) {
            activeTabId = tabs.first?.id
        }
    }

    /// Legacy: append to the "General" tab
    func append(_ text: String, isError: Bool = false) {
        let generalId: UUID
        if let existing = tabs.first(where: { $0.name == "General" }) {
            generalId = existing.id
        } else {
            generalId = createTab(name: "General")
        }
        append(to: generalId, text, isError: isError)
    }

    func clear() {
        tabs = []
        activeTabId = nil
    }
}
