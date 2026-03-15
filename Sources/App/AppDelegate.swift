import AppKit
import SwiftUI
import Combine

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
    private var cancellables = Set<AnyCancellable>()
    private var lastDirCacheTime: Date = .distantPast

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupHotkey()
        startScanning()
        summaryManager.start(appState: appState)
        hookServer.ensureHooksConfigured()
        hookServer.start()
        hookServer.discoverExistingSessions()
        updateChecker.checkForUpdates()

        // Update badge when terminal state or hook state changes
        appState.$terminalGroups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)

        hookServer.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanner.stopPolling()
        summaryManager.stop()
        hookServer.stop()
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

            // Find tabs that need directory caching:
            // - Brand new tabs (not in previous scan)
            // - Existing tabs that still have no cached directory (TTY wasn't ready last time)
            let allTabs = groups.flatMap { $0.tabs }
            let uncachedTabs = allTabs.filter { self.sessionStore.cachedDirectory(for: $0.id) == nil }
            let needsFullCache = Date().timeIntervalSince(self.lastDirCacheTime) > 60

            // Cache working directories:
            // 1. Always sync-cache tabs with no cached directory (new or pre-existing on first launch)
            // 2. Periodically async-refresh already-cached tabs + content every 60s
            if !uncachedTabs.isEmpty {
                for tab in uncachedTabs {
                    if let dir = self.summaryManager.contentReader.workingDirectory(tty: tab.tty) {
                        self.sessionStore.cacheDirectory(dir, for: tab.id)
                    }
                }
            }
            if needsFullCache {
                self.lastDirCacheTime = Date()
                let groupsCopy = groups
                DispatchQueue.global(qos: .utility).async {
                    for tab in allTabs {
                        if let dir = self.summaryManager.contentReader.workingDirectory(tty: tab.tty) {
                            DispatchQueue.main.async {
                                self.sessionStore.cacheDirectory(dir, for: tab.id)
                            }
                        }
                    }
                    // Cache last 500 lines of content for each tab (for session history)
                    for group in groupsCopy {
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
            }

            // Cache Claude session IDs and window frames
            for group in groups {
                // Window frame — one call per window, shared by all tabs in the group
                let frame = SessionStore.captureWindowFrame(app: group.app, windowID: group.windowID)
                for tab in group.tabs {
                    self.sessionStore.cacheWindowFrame(frame, for: tab.id)
                    if tab.isClaudeSession,
                       let cwd = self.sessionStore.cachedDirectory(for: tab.id),
                       let sid = self.hookServer.sessionID(forCwd: cwd) {
                        self.sessionStore.cacheClaudeSessionID(sid, for: tab.id)
                    }
                }
            }

            // Track closed sessions before updating state (uses cached dirs)
            if !previous.isEmpty {
                self.sessionStore.trackClosed(
                    current: groups,
                    previous: previous,
                    summaryFor: { self.summaryManager.summary(for: $0) }
                )
            }

            self.appState.updateActivity(groups: groups, previous: previous)
            self.appState.terminalGroups = groups

            // Prune restored session IDs whose terminal is no longer open
            let activeDirs = Set(allTabs.compactMap { self.sessionStore.cachedDirectory(for: $0.id) })
            self.sessionStore.pruneRestoredSessions(activeDirectories: activeDirs)
        }
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

        let hosting = NSHostingController(rootView: contentView)
        hosting.sizingOptions = .preferredContentSize

        popover = NSPopover()
        popover.contentSize = NSSize(width: 320, height: 100)
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
