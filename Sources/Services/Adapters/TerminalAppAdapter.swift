import AppKit
import Foundation

/// Scans Terminal.app windows and tabs via AppleScript
final class TerminalAppAdapter {

    private static let delimiter = "|||"
    private var hasLoggedPermissionError = false

    func scan() -> [TerminalGroup] {
        guard isRunning() else { return [] }

        // Quick permission check
        let checkScript = "tell application \"Terminal\" to count windows"
        guard let countStr = runAppleScript(checkScript),
              let count = Int(countStr), count > 0 else {
            if !hasLoggedPermissionError {
                hasLoggedPermissionError = true
                print("[TerminalAppAdapter] Cannot access Terminal.app — check Automation permission")
            }
            return []
        }
        hasLoggedPermissionError = false

        // Full scan — uses ||| as delimiter and ASCII char 10 (LF) for line breaks
        // AppleScript does NOT interpret \t or \n as escape sequences
        let script = """
        tell application "Terminal"
            set output to ""
            set lf to (ASCII character 10)
            repeat with w in windows
                set winID to (id of w as text)
                set winName to name of w
                set tabCount to count of tabs of w
                repeat with i from 1 to tabCount
                    set t to tab i of w
                    set tabTTY to tty of t
                    set tabBusy to (busy of t as text)
                    set tabProcs to processes of t
                    set procList to ""
                    repeat with p in tabProcs
                        if procList is not "" then set procList to procList & ","
                        set procList to procList & (p as text)
                    end repeat
                    set output to output & winID & "|||" & winName & "|||" & i & "|||" & tabTTY & "|||" & tabBusy & "|||" & procList & lf
                end repeat
            end repeat
            return output
        end tell
        """

        guard let result = runAppleScript(script) else { return [] }
        return parseResult(result)
    }

    private func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == TerminalApp.terminal.bundleIdentifier
        }
    }

    private func parseResult(_ raw: String) -> [TerminalGroup] {
        var windowMap: [String: TerminalGroup] = [:]
        var windowOrder: [String] = []
        let d = Self.delimiter

        for line in raw.components(separatedBy: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            let parts = line.components(separatedBy: d)
            guard parts.count >= 6 else { continue }

            let winID = parts[0].trimmingCharacters(in: .whitespaces)
            let winName = parts[1].trimmingCharacters(in: .whitespaces)
            let tabIndex = Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 1
            let tty = parts[3].trimmingCharacters(in: .whitespaces)
            let busy = parts[4].trimmingCharacters(in: .whitespaces) == "true"
            let processes = parts[5].trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            let status = determineStatus(busy: busy, processes: processes)
            let displayTitle = simplifyTitle(winName)

            let tab = TerminalTab(
                id: "terminal-\(winID)-\(tabIndex)",
                title: displayTitle,
                status: status,
                tty: tty,
                tabIndex: tabIndex - 1,  // Convert to 0-based
                processes: processes
            )

            let key = "terminal-\(winID)"
            if windowMap[key] == nil {
                windowMap[key] = TerminalGroup(
                    id: key,
                    app: .terminal,
                    windowTitle: simplifyWindowTitle(winName),
                    windowID: Int(winID) ?? 0,
                    tabs: [tab]
                )
                windowOrder.append(key)
            } else {
                windowMap[key]?.tabs.append(tab)
            }
        }

        return windowOrder.compactMap { windowMap[$0] }
    }

    private func determineStatus(busy: Bool, processes: [String]) -> TerminalStatus {
        let hasClaude = processes.contains { $0.contains("claude") }

        // Claude running but tab not busy = Claude finished, waiting for user
        if hasClaude && !busy {
            return .actionRequired
        }

        // If the only processes are login shell + shell, it's idle
        let shellProcesses = Set(["login", "-zsh", "zsh", "-bash", "bash", "fish", "-fish"])
        let nonShellProcesses = processes.filter { !shellProcesses.contains($0) && !$0.isEmpty }
        if nonShellProcesses.isEmpty {
            return .idle
        }

        return .running
    }

    private func simplifyTitle(_ title: String) -> String {
        var simplified = title

        // Remove dimension suffix like "— 147×70"
        if let dimRange = simplified.range(of: #" — \d+×\d+$"#, options: .regularExpression) {
            simplified = String(simplified[..<dimRange.lowerBound])
        }

        // Remove "— -zsh", "— bash" etc. from the end
        if let dashRange = simplified.range(of: " — ", options: .backwards) {
            let suffix = String(simplified[dashRange.upperBound...]).trimmingCharacters(in: .whitespaces)
            let shells = ["-zsh", "zsh", "-bash", "bash", "fish", "-fish", "login"]
            if shells.contains(suffix) {
                simplified = String(simplified[..<dashRange.lowerBound])
            }
        }

        // Remove user@host: prefix
        if let colonSpace = simplified.range(of: ": ") {
            let prefix = String(simplified[..<colonSpace.lowerBound])
            // Only strip if it looks like user@host
            if prefix.contains("@") {
                simplified = String(simplified[colonSpace.upperBound...])
            }
        }

        // Shorten home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        simplified = simplified.replacingOccurrences(of: home, with: "~")

        return simplified.isEmpty ? title : simplified
    }

    private func simplifyWindowTitle(_ title: String) -> String {
        let simplified = simplifyTitle(title)
        // For window title, just use "Terminal" if it's only a path
        if simplified.hasPrefix("~") || simplified.hasPrefix("/") {
            return "Terminal"
        }
        return simplified.isEmpty ? "Terminal" : simplified
    }

    // MARK: - AppleScript Execution

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)

        if let error = error {
            print("[TerminalAppAdapter] AppleScript error: \(error)")
            return nil
        }

        return result?.stringValue
    }
}
