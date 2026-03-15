import Foundation

/// Persists terminal sessions so they can be recovered after close
final class SessionStore: ObservableObject {
    @Published var recentlyClosed: [SavedSession] = []

    /// Cached working directories for live tabs (updated every scan)
    private var cachedDirectories: [String: String] = [:]
    /// Cached Claude session IDs for live tabs (by tab ID)
    private var cachedClaudeSessionIDs: [String: String] = [:]
    /// Tab IDs explicitly saved via Save & Close (auto-expires after 30s)
    private var explicitlySaved: [String: Date] = [:]
    /// Session IDs that have been restored (shown as active/green)
    @Published private(set) var restoredSessionIDs: Set<String> = []

    private let maxSaved = 20
    private let storageURL: URL
    private let restoredURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storageURL = dir.appendingPathComponent("sessions.json")
        restoredURL = dir.appendingPathComponent("restored.json")
        load()
    }

    // MARK: - Directory Cache

    func cacheDirectory(_ dir: String?, for tabID: String) {
        if let dir, !dir.isEmpty {
            cachedDirectories[tabID] = dir
        }
    }

    func cachedDirectory(for tabID: String) -> String? {
        cachedDirectories[tabID]
    }

    func cacheClaudeSessionID(_ sessionID: String?, for tabID: String) {
        if let sessionID, !sessionID.isEmpty {
            cachedClaudeSessionIDs[tabID] = sessionID
        }
    }

    // MARK: - Track Closed Tabs

    func trackClosed(
        current: [TerminalGroup],
        previous: [TerminalGroup],
        summaryFor: (String) -> String?
    ) {
        let currentIDs = Set(current.flatMap { $0.tabs }.map { $0.id })
        let previousTabs = previous.flatMap { g in g.tabs.map { (g, $0) } }

        var changed = false
        for (group, tab) in previousTabs where !currentIDs.contains(tab.id) {
            // Skip if already saved via explicit Save & Close (within 30s)
            if let savedAt = explicitlySaved.removeValue(forKey: tab.id),
               Date().timeIntervalSince(savedAt) < 30 {
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
        explicitlySaved[tab.id] = Date()
        save()

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
                command = "cd \\\"\(escapedDir)\\\" && claude --resume \(sid)"
            } else {
                command = "cd \\\"\(escapedDir)\\\" && claude --continue"
            }
        } else {
            command = "cd \\\"\(escapedDir)\\\" && clear"
        }

        // Use the correct terminal app
        let appName: String
        switch session.app {
        case TerminalApp.iterm.rawValue:
            appName = "iTerm2"
        default:
            appName = "Terminal"
        }

        let script = """
        tell application "\(appName)"
            activate
            do script "\(command)"
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error {
            print("[SessionStore] restore error: \(error)")
            return
        }

        restoredSessionIDs.insert(session.id)
        save()
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
        do {
            let data = try JSONEncoder().encode(Array(restoredSessionIDs))
            try data.write(to: restoredURL, options: .atomic)
        } catch {
            print("[SessionStore] save restored error: \(error)")
        }
    }

    private func load() {
        if FileManager.default.fileExists(atPath: storageURL.path) {
            do {
                let data = try Data(contentsOf: storageURL)
                recentlyClosed = try JSONDecoder().decode([SavedSession].self, from: data)
            } catch {
                print("[SessionStore] load error: \(error)")
            }
        }
        if FileManager.default.fileExists(atPath: restoredURL.path) {
            do {
                let data = try Data(contentsOf: restoredURL)
                let ids = try JSONDecoder().decode([String].self, from: data)
                restoredSessionIDs = Set(ids)
            } catch {
                print("[SessionStore] load restored error: \(error)")
            }
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
