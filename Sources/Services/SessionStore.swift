import Foundation

/// Persists terminal sessions so they can be recovered after close
final class SessionStore: ObservableObject {
    /// Explicitly saved sessions (via Save or Save & Close)
    @Published var savedSessions: [SavedSession] = []
    /// Auto-tracked closed terminal history
    @Published var closedHistory: [SavedSession] = []

    /// Cached working directories for live tabs (updated every scan)
    private var cachedDirectories: [String: String] = [:]
    /// Cached Claude session IDs for live tabs (by tab ID)
    private var cachedClaudeSessionIDs: [String: String] = [:]
    /// Cached window frames for live tabs (by tab ID)
    private var cachedWindowFrames: [String: WindowFrame] = [:]
    /// Cached terminal content for live tabs (last 500 lines, updated periodically)
    private var cachedContent: [String: String] = [:]
    /// Tab IDs explicitly saved via Save & Close (auto-expires after 30s)
    private var explicitlySaved: [String: Date] = [:]
    /// Session IDs that have been restored (shown as active/green)
    @Published private(set) var restoredSessionIDs: Set<String> = []
    /// Tab IDs that have been bookmarked via Save (still open, hidden from active list)
    @Published private(set) var savedTabIDs: Set<String> = []

    private let maxSaved = 20
    private let maxHistory = 50
    private let savedURL: URL
    private let historyURL: URL
    private let restoredURL: URL

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        savedURL = dir.appendingPathComponent("saved_sessions.json")
        historyURL = dir.appendingPathComponent("history.json")
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

    func cachedFrame(for tabID: String) -> WindowFrame? {
        cachedWindowFrames[tabID]
    }

    func cacheClaudeSessionID(_ sessionID: String?, for tabID: String) {
        if let sessionID, !sessionID.isEmpty {
            cachedClaudeSessionIDs[tabID] = sessionID
        } else {
            cachedClaudeSessionIDs.removeValue(forKey: tabID)
        }
    }

    func cachedClaudeSessionID(for tabID: String) -> String? {
        cachedClaudeSessionIDs[tabID]
    }

    // MARK: - Content Cache

    func cacheContent(_ content: String?, for tabID: String) {
        if let content, !content.isEmpty {
            cachedContent[tabID] = content
        }
    }

    // MARK: - Window Frame Cache

    func cacheWindowFrame(_ frame: WindowFrame?, for tabID: String) {
        if let frame {
            cachedWindowFrames[tabID] = frame
        }
    }

    /// Capture window bounds for a terminal window via AppleScript
    static func captureWindowFrame(app: TerminalApp, windowID: Int) -> WindowFrame? {
        let appName: String
        switch app {
        case .iterm: appName = "iTerm2"
        default: appName = "Terminal"
        }

        let script = """
        tell application "\(appName)"
            repeat with w in windows
                if id of w is \(windowID) then
                    set wBounds to bounds of w
                    return (item 1 of wBounds as text) & "," & (item 2 of wBounds as text) & "," & (item 3 of wBounds as text) & "," & (item 4 of wBounds as text)
                end if
            end repeat
        end tell
        """
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        guard let result = appleScript?.executeAndReturnError(&error).stringValue else { return nil }
        let parts = result.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: CharacterSet.whitespaces)) }
        guard parts.count == 4 else { return nil }
        return WindowFrame(x: parts[0], y: parts[1], width: parts[2] - parts[0], height: parts[3] - parts[1])
    }

    // MARK: - Track Closed Tabs (History only)

    /// Returns Claude session IDs that were on closed tabs (so caller can clean up hook server)
    @discardableResult
    func trackClosed(
        current: [TerminalGroup],
        previous: [TerminalGroup],
        summaryFor: (String) -> String?
    ) -> [String] {
        let currentIDs = Set(current.flatMap { $0.tabs }.map { $0.id })
        let previousTabs = previous.flatMap { g in g.tabs.map { (g, $0) } }

        var changed = false
        var closedClaudeSessionIDs: [String] = []
        for (group, tab) in previousTabs where !currentIDs.contains(tab.id) {
            // Skip if already saved via explicit Save & Close (within 30s)
            if let savedAt = explicitlySaved.removeValue(forKey: tab.id),
               Date().timeIntervalSince(savedAt) < 30 {
                cachedDirectories.removeValue(forKey: tab.id)
                cachedClaudeSessionIDs.removeValue(forKey: tab.id)
                cachedWindowFrames.removeValue(forKey: tab.id)
                cachedContent.removeValue(forKey: tab.id)
                continue
            }

            // Only save if we have a working directory — without it, restore is useless
            guard let dir = cachedDirectories[tab.id] else {
                cachedDirectories.removeValue(forKey: tab.id)
                cachedClaudeSessionIDs.removeValue(forKey: tab.id)
                cachedWindowFrames.removeValue(forKey: tab.id)
                cachedContent.removeValue(forKey: tab.id)
                continue
            }

            // For Claude sessions, only save if we have the session ID
            let claudeSID = cachedClaudeSessionIDs[tab.id]
            if tab.isClaudeSession && claudeSID == nil {
                cachedDirectories.removeValue(forKey: tab.id)
                cachedClaudeSessionIDs.removeValue(forKey: tab.id)
                cachedWindowFrames.removeValue(forKey: tab.id)
                cachedContent.removeValue(forKey: tab.id)
                continue
            }

            let frame = cachedWindowFrames[tab.id]
            let content = cachedContent[tab.id]
            let session = SavedSession(
                tabID: tab.id,
                title: tab.title,
                summary: summaryFor(tab.id) ?? tab.title,
                workingDirectory: dir,
                app: group.app.rawValue,
                wasClaudeSession: tab.isClaudeSession,
                claudeSessionID: claudeSID,
                windowFrame: frame,
                sessionTag: tab.sessionTag,
                content: content,
                closedAt: Date()
            )
            closedHistory.insert(session, at: 0)
            changed = true

            // Remove from saved tab tracking
            if savedTabIDs.contains(tab.id) {
                Log.info("trackClosed: removing tab=\(tab.id) from savedTabIDs (terminal closed)", category: "save")
            }
            savedTabIDs.remove(tab.id)

            // Collect Claude session IDs from closed tabs for hook server cleanup
            if let sid = cachedClaudeSessionIDs[tab.id] {
                closedClaudeSessionIDs.append(sid)
            }

            cachedDirectories.removeValue(forKey: tab.id)
            cachedClaudeSessionIDs.removeValue(forKey: tab.id)
            cachedWindowFrames.removeValue(forKey: tab.id)
            cachedContent.removeValue(forKey: tab.id)
        }

        if changed {
            if closedHistory.count > maxHistory {
                closedHistory = Array(closedHistory.prefix(maxHistory))
            }
            save()
        }
        return closedClaudeSessionIDs
    }

    // MARK: - Save (bookmark without closing)

    func saveSession(group: TerminalGroup, tab: TerminalTab, summary: String?,
                     contentReader: ContentReader? = nil, hookServer: ClaudeHookServer? = nil) {
        Log.info("saveSession: tab=\(tab.id) title=\(tab.title) isClaude=\(tab.isClaudeSession) window=\(group.windowID)", category: "save")
        // Don't save duplicates
        guard !savedTabIDs.contains(tab.id) else {
            Log.info("saveSession: SKIPPED — already saved (tab=\(tab.id))", category: "save")
            return
        }

        // Only Claude sessions can be saved
        guard tab.isClaudeSession else {
            Log.error("saveSession: ABORTED — not a Claude session (tab=\(tab.id))", category: "save")
            return
        }

        // Authoritative fresh lookup at save time (TTY→PID→CWD and TTY→PID→session)
        // No cache fallback — if we can't get fresh data, refuse to save
        guard let contentReader, let lookup = contentReader.authoritativeLookup(
            tty: tab.tty, isClaudeSession: true
        ) else {
            Log.error("saveSession: ABORTED — authoritative lookup failed (tab=\(tab.id) tty=\(tab.tty ?? "nil"))", category: "save")
            return
        }

        let dir = lookup.dir
        var claudeSID = lookup.sessionID

        // If --resume/file discovery didn't find session ID, try hook server with the FRESH dir
        if claudeSID == nil, let hookServer {
            claudeSID = hookServer.sessionID(forCwd: dir)
            if let claudeSID {
                Log.info("saveSession: hook server matched sid=\(claudeSID.prefix(8)) for fresh dir=\(dir)", category: "save")
            }
        }

        guard let claudeSID else {
            Log.error("saveSession: ABORTED — no session ID found (tab=\(tab.id) dir=\(dir))", category: "save")
            return
        }

        cachedDirectories[tab.id] = dir
        cachedClaudeSessionIDs[tab.id] = claudeSID
        Log.info("saveSession: authoritative dir=\(dir) sid=\(claudeSID.prefix(8))", category: "save")

        let frame = cachedWindowFrames[tab.id]
        let content = cachedContent[tab.id]

        let session = SavedSession(
            tabID: tab.id,
            title: tab.title,
            summary: summary ?? tab.title,
            workingDirectory: dir,
            app: group.app.rawValue,
            wasClaudeSession: tab.isClaudeSession,
            claudeSessionID: claudeSID,
            windowFrame: frame,
            sessionTag: tab.sessionTag,
            content: content,
            closedAt: Date()
        )
        savedSessions.insert(session, at: 0)
        savedTabIDs.insert(tab.id)
        if savedSessions.count > maxSaved {
            savedSessions = Array(savedSessions.prefix(maxSaved))
        }
        Log.info("saveSession: SAVED id=\(session.id.prefix(8)) dir=\(dir) claudeSID=\(claudeSID ?? "nil") frame=\(frame != nil)", category: "save")
        save()
    }

    // MARK: - Save & Close

    func saveAndClose(group: TerminalGroup, tab: TerminalTab, summary: String?,
                      contentReader: ContentReader? = nil, hookServer: ClaudeHookServer? = nil) {
        // Only Claude sessions can be saved
        guard tab.isClaudeSession else {
            closeTerminalWindow(app: group.app, windowID: group.windowID)
            return
        }

        // Authoritative fresh lookup — no cache fallback
        guard let contentReader, let lookup = contentReader.authoritativeLookup(
            tty: tab.tty, isClaudeSession: true
        ) else {
            closeTerminalWindow(app: group.app, windowID: group.windowID)
            return
        }

        let dir = lookup.dir
        var claudeSID = lookup.sessionID
        if claudeSID == nil, let hookServer {
            claudeSID = hookServer.sessionID(forCwd: dir)
        }

        guard let claudeSID else {
            closeTerminalWindow(app: group.app, windowID: group.windowID)
            return
        }

        cachedDirectories[tab.id] = dir
        cachedClaudeSessionIDs[tab.id] = claudeSID

        // Capture window frame and content before closing
        let frame = SessionStore.captureWindowFrame(app: group.app, windowID: group.windowID)
        let content = contentReader.readHistory(windowID: group.windowID, tabIndex: tab.tabIndex, app: group.app, lineCount: 500)
            ?? cachedContent[tab.id]

        // Remove any existing "Save" bookmark for this tab
        savedSessions.removeAll { $0.tabID == tab.id }
        savedTabIDs.remove(tab.id)

        let session = SavedSession(
            tabID: tab.id,
            title: tab.title,
            summary: summary ?? tab.title,
            workingDirectory: dir,
            app: group.app.rawValue,
            wasClaudeSession: tab.isClaudeSession,
            claudeSessionID: claudeSID,
            windowFrame: frame,
            sessionTag: tab.sessionTag,
            content: content,
            closedAt: Date()
        )
        savedSessions.insert(session, at: 0)
        if savedSessions.count > maxSaved {
            savedSessions = Array(savedSessions.prefix(maxSaved))
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
                        close w saving no
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
        Log.info("restore: id=\(session.id.prefix(8)) summary=\(session.summary) claude=\(session.wasClaudeSession) sid=\(session.claudeSessionID ?? "nil") dir=\(session.workingDirectory ?? "nil") app=\(session.app) frame=\(session.windowFrame != nil)", category: "restore")
        // Require working directory — should always be present since we don't save without it
        guard let dir = session.workingDirectory else {
            Log.error("restore: ABORTED — no working directory", category: "restore")
            return
        }
        let escapedDir = dir
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "$", with: "\\$")
            .replacingOccurrences(of: "`", with: "\\`")

        let command: String
        if session.wasClaudeSession {
            // Require session ID — should always be present since we don't save Claude sessions without it
            guard let sid = session.claudeSessionID else {
                Log.error("restore: ABORTED — Claude session but no session ID", category: "restore")
                return
            }
            // Validate session ID contains only safe characters to prevent command injection
            let isSafeSID = sid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            if isSafeSID && !sid.isEmpty {
                command = "cd \\\"\(escapedDir)\\\" && claude --resume \(sid)"
            } else {
                Log.error("restore: unsafe session ID '\(sid)', restoring without --resume", category: "restore")
                command = "cd \\\"\(escapedDir)\\\" && claude"
            }
        } else {
            command = "cd \\\"\(escapedDir)\\\" && clear"
        }
        Log.info("restore: command=\(command)", category: "restore")

        // Use the correct terminal app
        let appName: String
        switch session.app {
        case TerminalApp.iterm.rawValue:
            appName = "iTerm2"
        default:
            appName = "Terminal"
        }

        // Build restore script — optionally set window bounds on the correct window
        let boundsLiteral: String
        if let frame = session.windowFrame {
            boundsLiteral = "{\(frame.x), \(frame.y), \(frame.x + frame.width), \(frame.y + frame.height)}"
        } else {
            boundsLiteral = ""
        }

        let script: String
        if appName == "iTerm2" {
            // iTerm2: create window with default profile makes the new window frontmost (window 1)
            if boundsLiteral.isEmpty {
                script = """
                tell application "iTerm2"
                    activate
                    create window with default profile command "\(command)"
                end tell
                """
            } else {
                script = """
                tell application "iTerm2"
                    activate
                    create window with default profile command "\(command)"
                    set bounds of window 1 to \(boundsLiteral)
                end tell
                """
            }
        } else {
            // Terminal.app: "do script" returns a tab reference with a unique TTY.
            // We use that TTY to find the parent window reliably (avoids "front window" race).
            if boundsLiteral.isEmpty {
                script = """
                tell application "\(appName)"
                    activate
                    do script "\(command)"
                end tell
                """
            } else {
                script = """
                tell application "\(appName)"
                    activate
                    set newTab to do script "\(command)"
                    set targetTTY to tty of newTab
                    repeat with w in windows
                        repeat with t in tabs of w
                            if tty of t is targetTTY then
                                set bounds of w to \(boundsLiteral)
                                return
                            end if
                        end repeat
                    end repeat
                end tell
                """
            }
        }
        Log.info("restore: running AppleScript for \(appName)...", category: "restore")
        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        if let error {
            Log.error("restore: AppleScript FAILED — \(error)", category: "restore")
            return
        }
        Log.info("restore: AppleScript succeeded, result=\(result?.stringValue ?? "nil")", category: "restore")

        restoredSessionIDs.insert(session.id)
        save()
    }

    func dismissSaved(_ session: SavedSession) {
        Log.info("dismissSaved: id=\(session.id.prefix(8)) tabID=\(session.tabID) summary=\(session.summary)", category: "save")
        savedSessions.removeAll { $0.id == session.id }
        savedTabIDs.remove(session.tabID)
        restoredSessionIDs.remove(session.id)
        save()
    }

    func dismissHistory(_ session: SavedSession) {
        closedHistory.removeAll { $0.id == session.id }
        save()
    }

    /// Rename a saved session
    func renameSaved(_ session: SavedSession, to newName: String) {
        guard let idx = savedSessions.firstIndex(where: { $0.id == session.id }) else { return }
        savedSessions[idx] = savedSessions[idx].renamed(to: newName)
        save()
    }

    /// Move a history item into saved sessions
    func promoteToSaved(_ session: SavedSession) {
        closedHistory.removeAll { $0.id == session.id }
        savedSessions.insert(session, at: 0)
        if savedSessions.count > maxSaved {
            savedSessions = Array(savedSessions.prefix(maxSaved))
        }
        save()
    }

    /// Remove restored IDs whose terminal is no longer open (matched by CWD)
    func pruneRestoredSessions(activeDirectories: Set<String>) {
        let stale = restoredSessionIDs.filter { id in
            guard let session = savedSessions.first(where: { $0.id == id }),
                  let dir = session.workingDirectory else { return true }
            return !activeDirectories.contains(dir)
        }
        guard !stale.isEmpty else { return }
        for id in stale { restoredSessionIDs.remove(id) }
        save()
    }

    func clearSaved() {
        savedSessions.removeAll()
        savedTabIDs.removeAll()
        restoredSessionIDs.removeAll()
        save()
    }

    func clearHistory() {
        closedHistory.removeAll()
        save()
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(savedSessions)
            try data.write(to: savedURL, options: .atomic)
        } catch {
            print("[SessionStore] save error: \(error)")
        }
        do {
            let data = try JSONEncoder().encode(closedHistory)
            try data.write(to: historyURL, options: .atomic)
        } catch {
            print("[SessionStore] save history error: \(error)")
        }
        do {
            let data = try JSONEncoder().encode(Array(restoredSessionIDs))
            try data.write(to: restoredURL, options: .atomic)
        } catch {
            print("[SessionStore] save restored error: \(error)")
        }
    }

    private func load() {
        // Load saved sessions
        if FileManager.default.fileExists(atPath: savedURL.path) {
            do {
                let data = try Data(contentsOf: savedURL)
                savedSessions = try JSONDecoder().decode([SavedSession].self, from: data)
            } catch {
                print("[SessionStore] load saved error: \(error)")
            }
        }
        // Migrate old sessions.json → history
        let legacyURL = savedURL.deletingLastPathComponent().appendingPathComponent("sessions.json")
        if FileManager.default.fileExists(atPath: legacyURL.path) {
            do {
                let data = try Data(contentsOf: legacyURL)
                let legacy = try JSONDecoder().decode([SavedSession].self, from: data)
                closedHistory.append(contentsOf: legacy)
                try? FileManager.default.removeItem(at: legacyURL)
            } catch {
                print("[SessionStore] migrate legacy error: \(error)")
            }
        }
        // Load history
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do {
                let data = try Data(contentsOf: historyURL)
                let loaded = try JSONDecoder().decode([SavedSession].self, from: data)
                // Merge (avoid duplicates from migration)
                let existingIDs = Set(closedHistory.map { $0.id })
                closedHistory.append(contentsOf: loaded.filter { !existingIDs.contains($0.id) })
                closedHistory.sort { $0.closedAt > $1.closedAt }
            } catch {
                print("[SessionStore] load history error: \(error)")
            }
        }
        // Load restored IDs
        if FileManager.default.fileExists(atPath: restoredURL.path) {
            do {
                let data = try Data(contentsOf: restoredURL)
                let ids = try JSONDecoder().decode([String].self, from: data)
                restoredSessionIDs = Set(ids)
            } catch {
                print("[SessionStore] load restored error: \(error)")
            }
        }
        // Rebuild savedTabIDs
        savedTabIDs = Set(savedSessions.map { $0.tabID })
    }
}

// MARK: - Model

struct WindowFrame: Codable, Equatable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
}

struct SavedSession: Identifiable, Codable {
    let id: String
    let tabID: String
    let title: String
    var summary: String
    let workingDirectory: String?
    let app: String
    let wasClaudeSession: Bool
    let claudeSessionID: String?
    let windowFrame: WindowFrame?
    let sessionTag: String?
    let content: String?
    let closedAt: Date

    init(tabID: String, title: String, summary: String, workingDirectory: String?, app: String, wasClaudeSession: Bool = false, claudeSessionID: String? = nil, windowFrame: WindowFrame? = nil, sessionTag: String? = nil, content: String? = nil, closedAt: Date) {
        self.id = UUID().uuidString
        self.tabID = tabID
        self.title = title
        self.summary = summary
        self.workingDirectory = workingDirectory
        self.app = app
        self.wasClaudeSession = wasClaudeSession
        self.claudeSessionID = claudeSessionID
        self.windowFrame = windowFrame
        self.sessionTag = sessionTag
        self.content = content
        self.closedAt = closedAt
    }

    /// Effective tag — falls back to "claude"/"term" for sessions saved before tags existed
    var effectiveTag: String {
        sessionTag ?? (wasClaudeSession ? "claude" : "term")
    }

    /// Return a copy with a new summary (for renaming)
    func renamed(to newSummary: String) -> SavedSession {
        var copy = self
        copy.summary = newSummary
        return copy
    }
}
