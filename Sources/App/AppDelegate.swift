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
        hookServer.start()

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

            // Cache working directories every 30s (lsof is expensive)
            if Date().timeIntervalSince(self.lastDirCacheTime) > 30 {
                self.lastDirCacheTime = Date()
                DispatchQueue.global(qos: .utility).async {
                    for group in groups {
                        for tab in group.tabs {
                            if let dir = self.summaryManager.contentReader.workingDirectory(tty: tab.tty) {
                                DispatchQueue.main.async {
                                    self.sessionStore.cacheDirectory(dir, for: tab.id)
                                }
                            }
                        }
                    }
                }
            }

            // Cache Claude session IDs by matching cached cwd to hook server sessions
            for group in groups {
                for tab in group.tabs {
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
        }
    }

    // MARK: - Status Item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        guard let button = statusItem.button else { return }

        let config = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
        button.image = NSImage(
            systemSymbolName: "terminal.fill",
            accessibilityDescription: "Command"
        )?.withSymbolConfiguration(config)

        button.action = #selector(togglePopover)
        button.target = self

        updateBadge()
    }

    func updateBadge() {
        guard let button = statusItem?.button else { return }

        if appState.hasActionRequired || hookServer.hasActionRequired {
            button.image = NSImage(
                systemSymbolName: "terminal.fill",
                accessibilityDescription: "Command — action required"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
                    .applying(NSImage.SymbolConfiguration(paletteColors: [.controlAccentColor]))
            )
        } else {
            button.image = NSImage(
                systemSymbolName: "terminal.fill",
                accessibilityDescription: "Command"
            )?.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            )
        }
    }

    // MARK: - Popover

    private func setupPopover() {
        let contentView = TerminalListView()
            .environmentObject(appState)
            .environmentObject(summaryManager)
            .environmentObject(sessionStore)
            .environmentObject(hookServer)

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
        NSApp.activate(ignoringOtherApps: true)
    }

    func hidePopover() {
        popover.performClose(nil)
    }
}
