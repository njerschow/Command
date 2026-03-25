import AppKit
import SwiftUI
import Combine
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private let scanner = TerminalScanner()
    private let summaryManager = SummaryManager()
    private let sessionStore = SessionStore()
    private let hookServer = ClaudeHookServer()
    private let hotkeyManager = HotkeyManager()
    private let updateChecker = UpdateChecker()
    private let autopilotManager = AutopilotManager()
    private var cancellables = Set<AnyCancellable>()
    private var lastDirCacheTime: Date = .distantPast
    private var lastFrameCacheTime: Date = .distantPast
    private var pendingSummaryRefresh: DispatchWorkItem?
    private var knownTabIDs: Set<String> = []
    private let backgroundQueue = DispatchQueue(label: "com.command.scan-processing", qos: .userInitiated)

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        // Move CWD out of ~/Documents to prevent TCC prompts.
        // The app is built inside ~/Documents, so subprocesses (ps, lsof, claude)
        // inherit that CWD and trigger macOS Documents folder access prompts.
        FileManager.default.changeCurrentDirectoryPath("/tmp")

        enableLaunchAtLogin()
        setupStatusItem()
        setupPopover()
        setupHotkey()
        appState.loadPersistedActivity()
        startScanning()
        appState.startWakeObserver()
        summaryManager.start(appState: appState)
        hookServer.ensureHooksConfigured()
        hookServer.start()
        hookServer.startJSONLPolling()
        hookServer.discoverExistingSessions()
        autopilotManager.start(hookServer: hookServer, sessionStore: sessionStore)
        updateChecker.checkForUpdates()

        // Update badge when terminal state or hook state changes
        appState.$terminalGroups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        hookServer.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] hookSessions in
                guard let self else { return }
                self.updateBadge()
                // Bump activity for tabs whose Claude session had a state change
                for tab in self.appState.allTabs {
                    if let sid = self.sessionStore.cachedClaudeSessionID(for: tab.id),
                       let session = hookSessions[sid] {
                        // Use lastUpdated from hook session as a proxy for recent activity
                        let existing = self.appState.lastActivity[tab.id] ?? .distantPast
                        if session.lastUpdated > existing {
                            self.appState.lastActivity[tab.id] = session.lastUpdated
                        }
                    }
                }
            }
            .store(in: &cancellables)
    }

    private func enableLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status != .enabled {
            do {
                try service.register()
                Log.info("Registered launch-at-login", category: "lifecycle")
            } catch {
                Log.info("Failed to register launch-at-login: \(error)", category: "lifecycle")
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanner.stopPolling()
        summaryManager.stop()
        hookServer.stop()
        hookServer.stopJSONLPolling()
        autopilotManager.stop()
        hotkeyManager.unregister()
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager.register { [weak self] in
            DispatchQueue.main.async {
                self?.togglePopover()
            }
        }
    }

    // MARK: - Scanning

    private func startScanning() {
        scanner.startPolling(interval: 2.0) { [weak self] groups in
            guard let self else { return }
            let previous = self.appState.terminalGroups
            let allTabs = groups.flatMap { $0.tabs }

            // ---- Fast main-thread work: update UI state immediately ----

            // Track closed sessions (uses existing cached data, fast)
            if !previous.isEmpty {
                let closedSIDs = self.sessionStore.trackClosed(
                    current: groups,
                    previous: previous,
                    summaryFor: { self.summaryManager.summary(for: $0) }
                )
                if !closedSIDs.isEmpty {
                    Log.info("ghost cleanup: removing \(closedSIDs.count) closed session(s): \(closedSIDs.map { String($0.prefix(8)) })", category: "scan")
                }
                for sid in closedSIDs {
                    self.hookServer.removeSession(sid)
                }
            }

            self.appState.updateActivity(groups: groups, previous: previous)
            self.appState.terminalGroups = groups

            // Prune restored session IDs
            let activeDirs = Set(allTabs.compactMap { self.sessionStore.cachedDirectory(for: $0.id) })
            self.sessionStore.pruneRestoredSessions(activeDirectories: activeDirs)

            // Schedule summary refresh when new tabs appear
            let currentTabIDs = Set(allTabs.map { $0.id })
            let newTabs = currentTabIDs.subtracting(self.knownTabIDs)
            self.knownTabIDs = currentTabIDs
            if !newTabs.isEmpty {
                self.pendingSummaryRefresh?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.summaryManager.refresh()
                }
                self.pendingSummaryRefresh = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
            }

            // ---- Snapshot state for background processing ----

            let uncachedTabs = allTabs.filter { self.sessionStore.cachedDirectory(for: $0.id) == nil }
            let needsFullCache = Date().timeIntervalSince(self.lastDirCacheTime) > 60
            let needsFrameCapture = Date().timeIntervalSince(self.lastFrameCacheTime) > 5

            // Snapshot assigned session IDs and discovery tasks
            var assignedSessionIDs = Set<String>()
            for tab in allTabs {
                if let sid = self.sessionStore.cachedClaudeSessionID(for: tab.id),
                   let session = self.hookServer.sessions[sid],
                   !session.isFileDiscovered {
                    assignedSessionIDs.insert(sid)
                }
            }

            struct DiscoveryTask {
                let tabID: String
                let tty: String?
                let hasCachedDir: Bool
                let cachedDir: String?
            }
            var discoveryTasks: [DiscoveryTask] = []
            for tab in allTabs where tab.isClaudeSession {
                let existingSID = self.sessionStore.cachedClaudeSessionID(for: tab.id)
                let existingSession = existingSID.flatMap { self.hookServer.sessions[$0] }
                // Only re-discover if we have no session ID OR the session was removed from hookServer
                let needsDiscovery = existingSID == nil || existingSession == nil
                if needsDiscovery {
                    if existingSID != nil {
                        self.sessionStore.cacheClaudeSessionID(nil, for: tab.id)
                    }
                    let cachedDir = self.sessionStore.cachedDirectory(for: tab.id)
                    discoveryTasks.append(DiscoveryTask(
                        tabID: tab.id, tty: tab.tty,
                        hasCachedDir: cachedDir != nil, cachedDir: cachedDir
                    ))
                }
            }

            let hookSessionsSnapshot = self.hookServer.sessions
            if needsFullCache { self.lastDirCacheTime = Date() }
            if needsFrameCapture { self.lastFrameCacheTime = Date() }

            // ---- Background: heavy operations (subprocess calls, AppleScript) ----

            self.backgroundQueue.async {
                // CWD resolution for uncached tabs
                var dirUpdates: [(String, String)] = []
                for tab in uncachedTabs {
                    if let dir = self.summaryManager.contentReader.workingDirectory(tty: tab.tty) {
                        dirUpdates.append((tab.id, dir))
                    }
                }

                // Window frame capture (throttled to every 30s)
                var frameUpdates: [(String, WindowFrame?)] = []
                if needsFrameCapture {
                    for group in groups {
                        let frame = SessionStore.captureWindowFrame(app: group.app, windowID: group.windowID)
                        for tab in group.tabs {
                            frameUpdates.append((tab.id, frame))
                        }
                    }
                }

                // Claude session discovery
                var sidUpdates: [(tabID: String, sid: String)] = []
                var cwdUpdates: [(tabID: String, cwd: String)] = []
                var localAssigned = assignedSessionIDs
                for task in discoveryTasks {
                    var sid: String? = nil
                    if let discovered = self.summaryManager.contentReader.discoverClaudeSession(
                        tty: task.tty, excluding: localAssigned
                    ) {
                        if let hookSession = hookSessionsSnapshot[discovered.sessionID] {
                            sid = discovered.sessionID
                            let source = hookSession.isFileDiscovered ? "file-discovered" : "hook-confirmed"
                            Log.info("discovery: TTY match! sid=\(discovered.sessionID.prefix(8)) projectCwd=\(discovered.projectCwd) (\(source))", category: "scan")
                        } else {
                            // Session found via TTY but not in hookServer — register it as file-discovered
                            self.registerFileDiscoveredSession(sessionID: discovered.sessionID, cwd: discovered.projectCwd)
                            sid = discovered.sessionID
                            Log.info("discovery: TTY found sid=\(discovered.sessionID.prefix(8)), auto-registered as file-discovered", category: "scan")
                        }
                        if !task.hasCachedDir {
                            cwdUpdates.append((task.tabID, discovered.projectCwd))
                        }
                    }

                    // CWD fallback: match by working directory
                    if sid == nil {
                        let cwd = dirUpdates.first(where: { $0.0 == task.tabID })?.1 ?? task.cachedDir
                        if let cwd {
                            // Replicate sessionID(forCwd:) logic using snapshot
                            let normalized = self.normalizePath(cwd)
                            let match = hookSessionsSnapshot.values
                                .filter { self.normalizePath($0.cwd) == normalized && !localAssigned.contains($0.sessionID) }
                                .sorted { $0.lastUpdated > $1.lastUpdated }
                                .first
                            if let match {
                                sid = match.sessionID
                                Log.info("discovery: CWD fallback match sid=\(sid!.prefix(8)) cwd=\(cwd)", category: "scan")
                            }
                        }
                    }

                    if let sid {
                        sidUpdates.append((task.tabID, sid))
                        localAssigned.insert(sid)
                    } else {
                        Log.info("discovery: no match for tab=\(task.tabID) tty=\(task.tty ?? "nil")", category: "scan")
                    }
                }

                // Full CWD + content refresh (every 60s)
                if needsFullCache {
                    for tab in allTabs {
                        if let dir = self.summaryManager.contentReader.workingDirectory(tty: tab.tty) {
                            dirUpdates.append((tab.id, dir))
                        }
                    }
                    for group in groups {
                        for tab in group.tabs {
                            if let content = self.summaryManager.contentReader.readHistory(
                                windowID: group.windowID, tabIndex: tab.tabIndex, app: group.app, lineCount: 500
                            ) {
                                DispatchQueue.main.async {
                                    self.sessionStore.cacheContent(content, for: tab.id)
                                }
                            }
                        }
                    }
                }

                // ---- Apply results on main thread ----
                DispatchQueue.main.async {
                    for (tabID, dir) in dirUpdates {
                        // Don't overwrite project CWD for tabs with a valid Claude session ID
                        // (except for uncached tabs which need initial CWD)
                        if needsFullCache && self.sessionStore.cachedClaudeSessionID(for: tabID) != nil { continue }
                        self.sessionStore.cacheDirectory(dir, for: tabID)
                    }
                    for (tabID, frame) in frameUpdates {
                        self.sessionStore.cacheWindowFrame(frame, for: tabID)
                    }
                    for (tabID, sid) in sidUpdates {
                        self.sessionStore.cacheClaudeSessionID(sid, for: tabID)
                    }
                    for (tabID, cwd) in cwdUpdates {
                        if self.sessionStore.cachedDirectory(for: tabID) == nil {
                            self.sessionStore.cacheDirectory(cwd, for: tabID)
                        }
                    }
                }
            }
        }
    }

    /// Register a session discovered via TTY/file scanning into the hook server
    private func registerFileDiscoveredSession(sessionID: String, cwd: String) {
        hookServer.registerFileDiscovered(sessionID: sessionID, cwd: cwd)
    }

    /// Normalize path for CWD comparison (string-only, no filesystem access)
    private func normalizePath(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        if p == "/tmp" || p.hasPrefix("/tmp/") {
            p = "/private" + p
        }
        return p
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        guard let button = statusItem.button else { return }

        button.image = makeStatusIcon(highlighted: false)
        button.action = #selector(togglePopover)
        button.target = self

        updateBadge()
    }

    private func makeStatusIcon(highlighted: Bool) -> NSImage {
        let text = "⌘."
        let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: attrs)
        let padding = CGFloat(4)
        let height = CGFloat(18)
        let width = textSize.width + padding * 2
        let cornerRadius = CGFloat(4)
        let size = NSSize(width: width, height: height)

        // Draw filled rounded rect, then punch out the text to make it transparent
        let image = NSImage(size: size, flipped: false) { rect in
            // Fill the rounded rect
            let path = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: cornerRadius, yRadius: cornerRadius)
            NSColor.black.setFill()
            path.fill()

            // Clear the text area to make it transparent
            let textRect = NSRect(
                x: (rect.width - textSize.width) / 2,
                y: (rect.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            (text as NSString).draw(in: textRect, withAttributes: attrs)
            return true
        }
        image.isTemplate = true
        return image
    }

    func updateBadge() {
        // Badge updates disabled for now — icon stays static
    }

    // MARK: - Popover

    private func setupPopover() {
        let contentView = TerminalListView()
            .environmentObject(appState)
            .environmentObject(summaryManager)
            .environmentObject(sessionStore)
            .environmentObject(hookServer)
            .environmentObject(updateChecker)
            .environmentObject(autopilotManager)

        let hosting = NSHostingController(rootView: contentView)
        hosting.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.contentSize = NSSize(width: 400, height: 100)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = hosting
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        summaryManager.refreshIfNeeded()
        updateChecker.checkForUpdates()
        NSApp.activate(ignoringOtherApps: true)
    }

    func hidePopover() {
        popover.performClose(nil)
    }
}
