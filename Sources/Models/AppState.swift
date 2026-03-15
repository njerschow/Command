import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var terminalGroups: [TerminalGroup] = []
    @Published var isScanning = false

    var allTabs: [TerminalTab] {
        terminalGroups.flatMap { $0.tabs }
    }

    var hasActionRequired: Bool {
        terminalGroups.contains { $0.hasActionRequired }
    }

    /// Get the global index of the first tab in a group (for ⌘1-⌘9 shortcuts)
    func globalIndex(for group: TerminalGroup) -> Int {
        var index = 0
        for g in terminalGroups {
            if g.id == group.id { return index }
            index += g.tabs.count
        }
        return index
    }

    /// Get tab by global index
    func tab(at globalIndex: Int) -> (group: TerminalGroup, tab: TerminalTab)? {
        var index = 0
        for group in terminalGroups {
            for tab in group.tabs {
                if index == globalIndex {
                    return (group, tab)
                }
                index += 1
            }
        }
        return nil
    }

    // MARK: - Mock Data (will be replaced by real scanning)

    func loadMockData() {
        terminalGroups = [
            TerminalGroup(
                id: "term-w1",
                app: .terminal,
                windowTitle: "Terminal",
                windowID: 1001,
                tabs: [
                    TerminalTab(id: "t1", title: "~/Documents/random", status: .running, tty: "/dev/ttys001", tabIndex: 0),
                    TerminalTab(id: "t2", title: "~/Projects/api", status: .idle, tty: "/dev/ttys002", tabIndex: 1),
                    TerminalTab(id: "t3", title: "claude — waiting", status: .actionRequired, tty: "/dev/ttys003", tabIndex: 2),
                ]
            ),
            TerminalGroup(
                id: "term-w2",
                app: .terminal,
                windowTitle: "Terminal — logs",
                windowID: 1002,
                tabs: [
                    TerminalTab(id: "t4", title: "tail -f server.log", status: .running, tty: "/dev/ttys004", tabIndex: 0),
                ]
            ),
            TerminalGroup(
                id: "iterm-w1",
                app: .iterm,
                windowTitle: "iTerm2",
                windowID: 2001,
                tabs: [
                    TerminalTab(id: "i1", title: "node server.js", status: .running, tty: nil, tabIndex: 0),
                    TerminalTab(id: "i2", title: "~/Projects/web", status: .idle, tty: nil, tabIndex: 1),
                ]
            ),
        ]
    }
}
