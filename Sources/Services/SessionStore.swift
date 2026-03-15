import Foundation

/// Persists terminal sessions so they can be recovered after close
final class SessionStore: ObservableObject {
    @Published var recentlyClosed: [SavedSession] = []

    /// Cached working directories for live tabs (updated every scan)
    private var cachedDirectories: [String: String] = [:]

    private let maxSaved = 20
    private let storageURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("sessions.json")
        load()
    }

    // MARK: - Directory Cache

    /// Cache working directory for a live tab (call on every scan)
    func cacheDirectory(_ dir: String?, for tabID: String) {
        if let dir, !dir.isEmpty {
            cachedDirectories[tabID] = dir
        }
    }

    func cachedDirectory(for tabID: String) -> String? {
        cachedDirectories[tabID]
    }

    // MARK: - Track Closed Tabs

    /// Compare current scan with previous to detect closed tabs, saving their sessions
    func trackClosed(
        current: [TerminalGroup],
        previous: [TerminalGroup],
        summaryFor: (String) -> String?
    ) {
        let currentIDs = Set(current.flatMap { $0.tabs }.map { $0.id })
        let previousTabs = previous.flatMap { g in g.tabs.map { (g, $0) } }

        var changed = false
        for (group, tab) in previousTabs where !currentIDs.contains(tab.id) {
            let session = SavedSession(
                tabID: tab.id,
                title: tab.title,
                summary: summaryFor(tab.id) ?? tab.title,
                workingDirectory: cachedDirectories[tab.id],
                app: group.app.rawValue,
                wasClaudeSession: tab.isClaudeSession,
                closedAt: Date()
            )
            recentlyClosed.insert(session, at: 0)
            changed = true
            cachedDirectories.removeValue(forKey: tab.id)
        }

        if changed {
            if recentlyClosed.count > maxSaved {
                recentlyClosed = Array(recentlyClosed.prefix(maxSaved))
            }
            save()
        }
    }

    // MARK: - Save & Close

    /// Explicitly save a session and close its terminal window
    func saveAndClose(group: TerminalGroup, tab: TerminalTab, summary: String?) {
        let session = SavedSession(
            tabID: tab.id,
            title: tab.title,
            summary: summary ?? tab.title,
            workingDirectory: cachedDirectories[tab.id],
            app: group.app.rawValue,
            wasClaudeSession: tab.isClaudeSession,
            closedAt: Date()
        )
        recentlyClosed.insert(session, at: 0)
        if recentlyClosed.count > maxSaved {
            recentlyClosed = Array(recentlyClosed.prefix(maxSaved))
        }
        save()

        // Close the terminal window
        closeTerminalWindow(app: group.app, windowID: group.windowID)
    }

    private func closeTerminalWindow(app: TerminalApp, windowID: Int) {
        let script: String
        switch app {
        case .iterm:
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    if id of w is \(windowID) then
                        close w
                        return
                    end if
                end repeat
            end tell
            """
        default:
            script = """
            tell application "Terminal"
                repeat with w in windows
                    if id of w is \(windowID) then
                        close w
                        return
                    end if
                end repeat
            end tell
            """
        }
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error { print("[SessionStore] close error: \(error)") }
    }

    // MARK: - Restore

    func restore(_ session: SavedSession) {
        let dir = session.workingDirectory ?? NSHomeDirectory()
        let escapedDir = dir.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let command: String
        if session.wasClaudeSession {
            // Restore Claude Code session: cd to dir and launch claude
            command = "cd \\\"\(escapedDir)\\\" && claude"
        } else {
            command = "cd \\\"\(escapedDir)\\\" && clear"
        }

        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error { print("[SessionStore] restore error: \(error)") }

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
    let wasClaudeSession: Bool
    let closedAt: Date

    init(tabID: String, title: String, summary: String, workingDirectory: String?, app: String, wasClaudeSession: Bool = false, closedAt: Date) {
        self.id = UUID().uuidString
        self.tabID = tabID
        self.title = title
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.app = app
        self.wasClaudeSession = wasClaudeSession
        self.closedAt = closedAt
    }
}
