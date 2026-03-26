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

    /// CWD-based activity — survives tab ID changes across Terminal relaunches
    private var cwdActivity: [String: Date] = [:]

    private static let supportDir: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    private static let activityFile: URL = {
        supportDir.appendingPathComponent("lastActivity.json")
    }()

    private static let cwdActivityFile: URL = {
        supportDir.appendingPathComponent("cwdActivity.json")
    }()

    /// Suppress spurious activity updates right after system wake
    private var lastWakeTime: Date = .distantPast
    private var wakeObserver: Any?
    private static let wakeSuppressDuration: TimeInterval = 10

    func loadPersistedActivity() {
        if let data = try? Data(contentsOf: Self.activityFile),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            lastActivity = dict
        }
        if let data = try? Data(contentsOf: Self.cwdActivityFile),
           let dict = try? JSONDecoder().decode([String: Date].self, from: data) {
            cwdActivity = dict
        }
    }

    /// Restore activity for a tab from its CWD history (call after CWD is resolved)
    func restoreActivityFromCwd(_ cwd: String, for tabID: String) {
        guard lastActivity[tabID] == nil else { return }
        if let saved = cwdActivity[cwd] {
            lastActivity[tabID] = saved
        }
        // If no CWD history, leave nil — the tab will show no time rather than a fake "now"
    }

    /// Associate a CWD with the current activity timestamp for a tab
    func trackCwdActivity(_ cwd: String, for tabID: String) {
        guard let date = lastActivity[tabID] else { return }
        let existing = cwdActivity[cwd] ?? .distantPast
        if date > existing {
            cwdActivity[cwd] = date
            persistCwdActivity()
        }
    }

    private var persistTimer: Timer?
    private var cwdPersistTimer: Timer?

    private func persistActivity() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self, let data = try? JSONEncoder().encode(self.lastActivity) else { return }
            try? data.write(to: Self.activityFile, options: .atomic)
        }
    }

    private func persistCwdActivity() {
        cwdPersistTimer?.invalidate()
        cwdPersistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Prune CWD entries older than 30 days
            let cutoff = Date().addingTimeInterval(-30 * 24 * 3600)
            let pruned = self.cwdActivity.filter { $0.value > cutoff }
            if pruned.count != self.cwdActivity.count { self.cwdActivity = pruned }
            guard let data = try? JSONEncoder().encode(self.cwdActivity) else { return }
            try? data.write(to: Self.cwdActivityFile, options: .atomic)
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
                    // Only track status transitions (idle↔running↔actionRequired) as real activity.
                    // Process list churn (background procs starting/stopping) is too noisy.
                    if prev.status != tab.status {
                        lastActivity[tab.id] = Date()
                    }
                } else {
                    // New tab — don't stamp yet; let restoreActivityFromCwd
                    // set the correct historical timestamp once CWD is resolved.
                    // If no CWD match exists, it'll get stamped on first real change.
                }
            }
        }

        // Prune entries older than 7 days (don't prune by tab ID — IDs change across relaunches)
        let cutoff = Date().addingTimeInterval(-7 * 24 * 3600)
        for (key, date) in lastActivity where date < cutoff {
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
