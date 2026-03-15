import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var terminalGroups: [TerminalGroup] = []
    @Published var isScanning = false

    /// Scan-based activity tracking (updated every 2s on status/title change)
    @Published var lastActivity: [String: Date] = [:]

    var allTabs: [TerminalTab] {
        terminalGroups.flatMap { $0.tabs }
    }

    var hasActionRequired: Bool {
        terminalGroups.contains { $0.hasActionRequired }
    }

    /// Groups sorted by most recent activity (MRU)
    var sortedGroups: [TerminalGroup] {
        terminalGroups.sorted { a, b in
            let aMax = a.tabs.compactMap { lastActivity[$0.id] }.max() ?? .distantPast
            let bMax = b.tabs.compactMap { lastActivity[$0.id] }.max() ?? .distantPast
            return aMax > bMax
        }
    }

    /// Update activity timestamps by comparing with previous scan
    func updateActivity(groups: [TerminalGroup], previous: [TerminalGroup]) {
        let prevTabs = Dictionary(
            previous.flatMap { $0.tabs }.map { ($0.id, $0) },
            uniquingKeysWith: { _, b in b }
        )

        for group in groups {
            for tab in group.tabs {
                if let prev = prevTabs[tab.id] {
                    if prev.status != tab.status || prev.title != tab.title {
                        lastActivity[tab.id] = Date()
                    }
                } else {
                    // New tab — only timestamp if it's actively doing something
                    if tab.status != .idle {
                        lastActivity[tab.id] = Date()
                    }
                }
            }
        }

        // Prune tabs that no longer exist
        let activeIDs = Set(groups.flatMap { $0.tabs }.map { $0.id })
        for key in lastActivity.keys where !activeIDs.contains(key) {
            lastActivity.removeValue(forKey: key)
        }
    }

    /// Get the global index of the first tab in a group (for ⌘1-⌘9 shortcuts)
    func globalIndex(for group: TerminalGroup) -> Int {
        var index = 0
        for g in sortedGroups {
            if g.id == group.id { return index }
            index += g.tabs.count
        }
        return index
    }

    /// Get tab by global index (uses sorted order)
    func tab(at globalIndex: Int) -> (group: TerminalGroup, tab: TerminalTab)? {
        var index = 0
        for group in sortedGroups {
            for tab in group.tabs {
                if index == globalIndex {
                    return (group, tab)
                }
                index += 1
            }
        }
        return nil
    }
}
