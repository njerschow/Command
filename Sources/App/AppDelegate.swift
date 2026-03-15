import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()
    private let scanner = TerminalScanner()
    private let hotkeyManager = HotkeyManager()
    private let claudeServer = ClaudeHookServer()
    private var cancellables = Set<AnyCancellable>()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()
        setupHotkey()
        setupClaudeServer()
        startScanning()

        // Update badge when terminal state changes
        appState.$terminalGroups
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateBadge() }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        scanner.stopPolling()
        hotkeyManager.unregister()
        claudeServer.stop()
    }

    // MARK: - Hotkey

    private func setupHotkey() {
        hotkeyManager.register { [weak self] in
            DispatchQueue.main.async {
                self?.togglePopover()
            }
        }
    }

    // MARK: - Claude Code Integration

    private func setupClaudeServer() {
        claudeServer.onSessionUpdate = { [weak self] in
            // Trigger a rescan when Claude state changes
            guard let self else { return }
            let groups = self.scanner.scan()
            self.appState.terminalGroups = groups
        }
        claudeServer.start()

        // Give the scanner access to Claude session data
        scanner.claudeServer = claudeServer
    }

    // MARK: - Scanning

    private func startScanning() {
        scanner.startPolling(interval: 2.0) { [weak self] groups in
            self?.appState.terminalGroups = groups
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

        if appState.hasActionRequired {
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
        NSApp.activate(ignoringOtherApps: true)
    }

    func hidePopover() {
        popover.performClose(nil)
    }
}
