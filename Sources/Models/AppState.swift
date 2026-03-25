import AppKit
import Foundation
import Combine

final class AppState: ObservableObject {
    @Published var terminalGroups: [TerminalGroup] = []
    @Published var isScanning = false

    /// Scan-based activity tracking — only updated on meaningful changes
    @Published var lastActivity: [String: Date] = [:] {
        didSet { persistActivity() }
    }

    private static let activityFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("lastActivity.json")
    }()

    /// Suppress spurious activity updates right after system wake
    private var lastWakeTime: Date = .distantPast
    private var wakeObserver: Any?
    private static let wakeSuppressDuration: TimeInterval = 10

    func loadPersistedActivity() {
        guard let data = try? Data(contentsOf: Self.activityFile),
              let dict = try? JSONDecoder().decode([String: Date].self, from: data) else { return }
        lastActivity = dict
    }

    private var persistTimer: Timer?

    private func persistActivity() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(self.lastActivity) else { return }
            try? data.write(to: Self.activityFile, options: .atomic)
        }
    }

    func startWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastWakeTime = Date()
            Log.info("system wake detected, suppressing activity updates for \(Self.wakeSuppressDuration)s", category: "scan")
        }
    }

    private var isInWakeSuppression: Bool {
        Date().timeIntervalSince(lastWakeTime) < Self.wakeSuppressDuration
    }

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

    /// Manually bump a tab's activity timestamp (e.g. when user clicks it)
    func touchActivity(tabID: String) {
        lastActivity[tabID] = Date()
    }

    /// Update activity timestamps by comparing with previous scan.
    /// Only fires on meaningful changes, suppressed during post-wake period.
    func updateActivity(groups: [TerminalGroup], previous: [TerminalGroup]) {
        // Skip updates right after wake — Terminal reconnects cause spurious changes
        guard !isInWakeSuppression else { return }

        let prevTabs = Dictionary(
            previous.flatMap { $0.tabs }.map { ($0.id, $0) },
            uniquingKeysWith: { _, b in b }
        )

        for group in groups {
            for tab in group.tabs {
                if let prev = prevTabs[tab.id] {
                    // Track status transitions and process list changes as activity
                    let changed = prev.status != tab.status || prev.processes != tab.processes
                    if changed {
                        lastActivity[tab.id] = Date()
                    }
                } else {
                    // New tab — always timestamp it
                    lastActivity[tab.id] = Date()
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
