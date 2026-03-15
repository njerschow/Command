import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let appState = AppState()

    // MARK: - Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusItem()
        setupPopover()

        // Load mock data for now
        appState.loadMockData()
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

        // Show a small dot overlay when action is required
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
