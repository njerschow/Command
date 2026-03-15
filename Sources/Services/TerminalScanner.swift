import Foundation
import Combine

/// Coordinates scanning across all terminal adapters
final class TerminalScanner {
    private let terminalAdapter = TerminalAppAdapter()
    private var timer: Timer?

    /// Set by AppDelegate to enable Claude Code status enrichment
    var claudeServer: ClaudeHookServer?

    /// Scan all terminal apps and return grouped results
    func scan() -> [TerminalGroup] {
        var groups: [TerminalGroup] = []

        // Terminal.app
        groups.append(contentsOf: terminalAdapter.scan())

        // TODO: iTerm2, Kitty, Ghostty, Warp adapters

        // Enrich with Claude Code session data
        if let server = claudeServer {
            groups = enrichWithClaudeStatus(groups, server: server)
        }

        return groups
    }

    /// Start periodic scanning
    func startPolling(interval: TimeInterval = 2.0, onUpdate: @escaping ([TerminalGroup]) -> Void) {
        stopPolling()

        // Scan immediately
        let results = scan()
        onUpdate(results)

        // Then poll on interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let results = self.scan()
            DispatchQueue.main.async {
                onUpdate(results)
            }
        }
    }

    /// Stop periodic scanning
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Claude Code Enrichment

    private func enrichWithClaudeStatus(_ groups: [TerminalGroup], server: ClaudeHookServer) -> [TerminalGroup] {
        return groups.map { group in
            var enrichedGroup = group
            enrichedGroup.tabs = group.tabs.map { tab in
                var enrichedTab = tab

                // Try to match Claude sessions to tabs via working directory
                // The tab title often contains the path, and Claude hooks include cwd
                if let session = findClaudeSession(for: tab, in: server) {
                    switch session.state {
                    case .waitingForUser, .needsPermission:
                        enrichedTab = TerminalTab(
                            id: tab.id,
                            title: "claude — \(session.lastEvent)",
                            status: .actionRequired,
                            tty: tab.tty,
                            tabIndex: tab.tabIndex
                        )
                    case .working:
                        enrichedTab = TerminalTab(
                            id: tab.id,
                            title: "claude — \(session.lastEvent)",
                            status: .running,
                            tty: tab.tty,
                            tabIndex: tab.tabIndex
                        )
                    }
                }

                return enrichedTab
            }
            return enrichedGroup
        }
    }

    private func findClaudeSession(for tab: TerminalTab, in server: ClaudeHookServer) -> ClaudeSession? {
        // Match by working directory from tab title
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expandedTitle = tab.title.replacingOccurrences(of: "~", with: home)

        // Check if any Claude session's cwd matches the tab's apparent directory
        for (_, session) in server.sessions {
            if session.cwd == expandedTitle || tab.title.contains(session.cwd) ||
                session.cwd.hasSuffix(tab.title.replacingOccurrences(of: "~/", with: "")) {
                return session
            }
        }

        return nil
    }
}
