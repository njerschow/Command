import Foundation
import AppKit

// MARK: - Terminal Application

enum TerminalApp: String, CaseIterable, Identifiable {
    case terminal = "Terminal"
    case iterm = "iTerm2"
    case kitty = "Kitty"
    case ghostty = "Ghostty"
    case warp = "Warp"
    case alacritty = "Alacritty"
    case unknown = "Unknown"

    var id: String { rawValue }

    var bundleIdentifier: String {
        switch self {
        case .terminal: return "com.apple.Terminal"
        case .iterm: return "com.googlecode.iterm2"
        case .kitty: return "net.kovidgoyal.kitty"
        case .ghostty: return "com.mitchellh.ghostty"
        case .warp: return "dev.warp.Warp-Stable"
        case .alacritty: return "org.alacritty"
        case .unknown: return ""
        }
    }

    var icon: NSImage? {
        if let path = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return NSWorkspace.shared.icon(forFile: path.path)
        }
        return NSImage(systemSymbolName: "terminal", accessibilityDescription: rawValue)
    }
}

// MARK: - Status

enum TerminalStatus: Equatable {
    case idle
    case running
    case actionRequired
}

// MARK: - Tab

struct TerminalTab: Identifiable, Equatable {
    let id: String
    let title: String
    let status: TerminalStatus
    let tty: String?
    let tabIndex: Int
    let processes: [String]

    var isClaudeSession: Bool {
        processes.contains { $0.contains("claude") }
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.status == rhs.status
    }
}

// MARK: - Window Group

struct TerminalGroup: Identifiable, Equatable {
    let id: String
    let app: TerminalApp
    let windowTitle: String
    let windowID: Int
    var tabs: [TerminalTab]

    var displayName: String {
        if !windowTitle.isEmpty {
            return windowTitle
        }
        return app.rawValue
    }

    var hasActionRequired: Bool {
        tabs.contains { $0.status == .actionRequired }
    }

    static func == (lhs: TerminalGroup, rhs: TerminalGroup) -> Bool {
        lhs.id == rhs.id && lhs.tabs == rhs.tabs
    }
}
