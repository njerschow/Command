import Foundation

/// Persists terminal sessions so they can be recovered after close
final class SessionStore: ObservableObject {
    @Published var recentlyClosed: [SavedSession] = []

    private let maxSaved = 20
    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("sessions.json")
        load()
    }

    // MARK: - Track Closed Tabs

    /// Compare current scan with previous to detect closed tabs, saving their sessions
    func trackClosed(
        current: [TerminalGroup],
        previous: [TerminalGroup],
        summaryFor: (String) -> String?,
        directoryFor: (String) -> String?
    ) {
        let currentIDs = Set(current.flatMap { $0.tabs }.map { $0.id })
        let previousTabs = previous.flatMap { g in g.tabs.map { (g, $0) } }

        var changed = false
        for (group, tab) in previousTabs where !currentIDs.contains(tab.id) {
            let session = SavedSession(
                tabID: tab.id,
                title: tab.title,
                summary: summaryFor(tab.id) ?? tab.title,
                workingDirectory: directoryFor(tab.id),
                app: group.app.rawValue,
                closedAt: Date()
            )
            recentlyClosed.insert(session, at: 0)
            changed = true
        }

        if changed {
            // Cap and persist
            if recentlyClosed.count > maxSaved {
                recentlyClosed = Array(recentlyClosed.prefix(maxSaved))
            }
            save()
        }
    }

    // MARK: - Restore

    func restore(_ session: SavedSession) {
        let dir = session.workingDirectory ?? "~"
        let script = """
        tell application "Terminal"
            activate
            do script "cd \(dir.replacingOccurrences(of: "\"", with: "\\\""))"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error { print("[SessionStore] restore error: \(error)") }

        // Remove from recently closed
        recentlyClosed.removeAll { $0.id == session.id }
        save()
    }

    func dismiss(_ session: SavedSession) {
        recentlyClosed.removeAll { $0.id == session.id }
        save()
    }

    func clearAll() {
        recentlyClosed.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(recentlyClosed)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            print("[SessionStore] save error: \(error)")
        }
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: storageURL.path) else { return }
        do {
            let data = try Data(contentsOf: storageURL)
            recentlyClosed = try JSONDecoder().decode([SavedSession].self, from: data)
        } catch {
            print("[SessionStore] load error: \(error)")
        }
    }
}

// MARK: - Model

struct SavedSession: Identifiable, Codable {
    let id: String
    let tabID: String
    let title: String
    let summary: String
    let workingDirectory: String?
    let app: String
    let closedAt: Date

    init(tabID: String, title: String, summary: String, workingDirectory: String?, app: String, closedAt: Date) {
        self.id = UUID().uuidString
        self.tabID = tabID
        self.title = title
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.app = app
        self.closedAt = closedAt
    }
}
