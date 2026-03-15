import Foundation

/// Persists terminal sessions so they can be recovered after close
final class SessionStore: ObservableObject {
    @Published var recentlyClosed: [SavedSession] = []

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
            recentlyClosed.insert(session, at: 0)
            changed = true
            cachedDirectories.removeValue(forKey: tab.id)
            cachedClaudeSessionIDs.removeValue(forKey: tab.id)
            cachedWindowFrames.removeValue(forKey: tab.id)
            cachedContent.removeValue(forKey: tab.id)
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

        // Don't save without a directory — restore would be useless
        guard let dir else {
            closeTerminalWindow(app: group.app, windowID: group.windowID)
            return
        }

        // Resolve Claude session ID NOW
        var claudeSID = cachedClaudeSessionIDs[tab.id]
        if claudeSID == nil, tab.isClaudeSession, let hookServer {
            claudeSID = hookServer.sessionID(forCwd: dir)
            if let claudeSID { cachedClaudeSessionIDs[tab.id] = claudeSID }
        }

        // For Claude sessions, require session ID
        if tab.isClaudeSession && claudeSID == nil {
            closeTerminalWindow(app: group.app, windowID: group.windowID)
            return
        }

        // Capture window frame and content before closing
        let frame = SessionStore.captureWindowFrame(app: group.app, windowID: group.windowID)
        let content = contentReader?.readHistory(windowID: group.windowID, tabIndex: tab.tabIndex, app: group.app, lineCount: 500)
            ?? cachedContent[tab.id]

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
        // Require working directory — should always be present since we don't save without it
        guard let dir = session.workingDirectory else { return }
        let escapedDir = dir.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")

        let command: String
        if session.wasClaudeSession {
            // Require session ID — should always be present since we don't save Claude sessions without it
            guard let sid = session.claudeSessionID else { return }
            command = "cd \\\"\(escapedDir)\\\" && claude --resume \(sid)"
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

        // Build restore script — optionally set window bounds
        var setBounds = ""
        if let frame = session.windowFrame {
            setBounds = "\n            set bounds of window 1 to {\(frame.x), \(frame.y), \(frame.x + frame.width), \(frame.y + frame.height)}"
        }

        let script = """
        tell application "\(appName)"
            activate
            do script "\(command)"\(setBounds)
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

    /// Remove restored IDs whose terminal is no longer open (matched by CWD)
    func pruneRestoredSessions(activeDirectories: Set<String>) {
        let stale = restoredSessionIDs.filter { id in
            guard let session = recentlyClosed.first(where: { $0.id == id }),
                  let dir = session.workingDirectory else { return true }
            return !activeDirectories.contains(dir)
        }
        guard !stale.isEmpty else { return }
        for id in stale { restoredSessionIDs.remove(id) }
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
    let summary: String
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
}
