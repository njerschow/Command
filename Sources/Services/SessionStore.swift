import Foundation

/// Persists terminal sessions so they can be recovered after close
final class SessionStore: ObservableObject {
    @Published var recentlyClosed: [SavedSession] = []

    /// Cached working directories for live tabs (updated every scan)
    private var cachedDirectories: [String: String] = [:]
    /// Cached Claude session IDs for live tabs (by tab ID)
    private var cachedClaudeSessionIDs: [String: String] = [:]
    /// Tab IDs explicitly saved via Save & Close (to prevent duplicate tracking)
    private var explicitlySaved: Set<String> = []
    /// Session IDs that have been restored (shown as active/green)
    private(set) var restoredSessionIDs: Set<String> = []

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

    /// Cache Claude session ID for a live tab
    func cacheClaudeSessionID(_ sessionID: String?, for tabID: String) {
        if let sessionID, !sessionID.isEmpty {
            cachedClaudeSessionIDs[tabID] = sessionID
        }
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
            // Skip if already saved via explicit Save & Close
            if explicitlySaved.remove(tab.id) != nil {
                cachedDirectories.removeValue(forKey: tab.id)
                cachedClaudeSessionIDs.removeValue(forKey: tab.id)
                continue
            }

            // Skip if a saved session already exists for this directory (e.g. restored session closed)
            if let dir = cachedDirectories[tab.id],
               recentlyClosed.contains(where: { $0.workingDirectory == dir }) {
                cachedDirectories.removeValue(forKey: tab.id)
                cachedClaudeSessionIDs.removeValue(forKey: tab.id)
                continue
            }

            let session = SavedSession(
                tabID: tab.id,
                title: tab.title,
                summary: summaryFor(tab.id) ?? tab.title,
                workingDirectory: cachedDirectories[tab.id],
                app: group.app.rawValue,
                wasClaudeSession: tab.isClaudeSession,
                claudeSessionID: cachedClaudeSessionIDs[tab.id],
                closedAt: Date()
            )
            recentlyClosed.insert(session, at: 0)
            changed = true
            cachedDirectories.removeValue(forKey: tab.id)
            cachedClaudeSessionIDs.removeValue(forKey: tab.id)
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
    /// Pass contentReader and hookServer for real-time resolution (not just cached values)
    func saveAndClose(group: TerminalGroup, tab: TerminalTab, summary: String?,
                      contentReader: ContentReader? = nil, hookServer: ClaudeHookServer? = nil) {
        // Resolve directory NOW (in case cache hasn't populated yet)
        var dir = cachedDirectories[tab.id]
        if dir == nil, let contentReader {
            dir = contentReader.workingDirectory(tty: tab.tty)
            if let dir { cachedDirectories[tab.id] = dir }
        }

        // Resolve Claude session ID NOW
        var claudeSID = cachedClaudeSessionIDs[tab.id]
        if claudeSID == nil, tab.isClaudeSession, let dir, let hookServer {
            claudeSID = hookServer.sessionID(forCwd: dir)
            if let claudeSID { cachedClaudeSessionIDs[tab.id] = claudeSID }
        }

        let session = SavedSession(
            tabID: tab.id,
            title: tab.title,
            summary: summary ?? tab.title,
            workingDirectory: dir,
            app: group.app.rawValue,
            wasClaudeSession: tab.isClaudeSession,
            claudeSessionID: claudeSID,
            closedAt: Date()
        )
        recentlyClosed.insert(session, at: 0)
        if recentlyClosed.count > maxSaved {
            recentlyClosed = Array(recentlyClosed.prefix(maxSaved))
        }
        explicitlySaved.insert(tab.id)
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
            if let sid = session.claudeSessionID {
                // Resume exact Claude session
                command = "cd \\\"\(escapedDir)\\\" && claude --resume \(sid)"
            } else {
                // No session ID — continue most recent in that directory
                command = "cd \\\"\(escapedDir)\\\" && claude --continue"
            }
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

        // Mark as restored — shows green dot immediately
        restoredSessionIDs.insert(session.id)
    }

    func dismiss(_ session: SavedSession) {
        recentlyClosed.removeAll { $0.id == session.id }
        restoredSessionIDs.remove(session.id)
        save()
    }

    func clearAll() {
        recentlyClosed.removeAll()
        restoredSessionIDs.removeAll()
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
    let claudeSessionID: String?
    let closedAt: Date

    init(tabID: String, title: String, summary: String, workingDirectory: String?, app: String, wasClaudeSession: Bool = false, claudeSessionID: String? = nil, closedAt: Date) {
        self.id = UUID().uuidString
        self.tabID = tabID
        self.title = title
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.app = app
        self.wasClaudeSession = wasClaudeSession
        self.claudeSessionID = claudeSessionID
        self.closedAt = closedAt
    }
}
