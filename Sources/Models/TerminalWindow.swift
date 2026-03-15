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

    /// Detect the primary session type from running processes.
    /// Checks highest-priority tags across ALL processes first (e.g. claude always wins over node).
    var sessionTag: String {
        let shellNames: Set<String> = ["login", "-zsh", "zsh", "-bash", "bash", "fish", "-fish", "sh", "-sh"]
        let procs = Set(processes.filter { !$0.isEmpty && !shellNames.contains($0) })
        if procs.isEmpty { return "term" }

        // Priority order: check each tag across all processes before moving to next tag
        if procs.contains(where: { $0.contains("openclaw") }) { return "openclaw" }
        if procs.contains(where: { $0.contains("claude") }) { return "claude" }
        if procs.contains("ssh") || procs.contains("sshd") || procs.contains("mosh-client") { return "ssh" }
        if procs.contains("nvim") || procs.contains("vim") || procs.contains("vi") { return "vim" }
        if procs.contains("emacs") { return "emacs" }
        if procs.contains(where: { $0.contains("python") }) { return "python" }
        if procs.contains("node") || procs.contains("deno") || procs.contains("bun") { return "node" }
        if procs.contains("cargo") || procs.contains("rustc") { return "cargo" }
        if procs.contains("go") { return "go" }
        if procs.contains("make") || procs.contains("cmake") { return "make" }
        if procs.contains("docker") || procs.contains("docker-compose") { return "docker" }
        if procs.contains("git") { return "git" }
        if procs.contains("npm") || procs.contains("yarn") || procs.contains("pnpm") { return "npm" }
        if procs.contains("ruby") || procs.contains("irb") { return "ruby" }
        if procs.contains("htop") || procs.contains("top") || procs.contains("btop") { return "top" }
        return "term"
    }

    static func == (lhs: TerminalTab, rhs: TerminalTab) -> Bool {
        lhs.id == rhs.id && lhs.title == rhs.title && lhs.status == rhs.status && lhs.processes == rhs.processes
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
