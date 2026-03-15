import AppKit
import Foundation

/// Scans Terminal.app windows and tabs via AppleScript
final class TerminalAppAdapter {

    func scan() -> [TerminalGroup] {
        guard isRunning() else { return [] }

        let script = """
        tell application "Terminal"
            set output to ""
            set winIndex to 0
            repeat with w in windows
                set winIndex to winIndex + 1
                set winID to id of w
                set winName to name of w
                set tabCount to count of tabs of w
                set tabIndex to 0
                repeat with t in tabs of w
                    set tabIndex to tabIndex + 1
                    set tabName to name of t  -- custom title or process
                    set tabTTY to tty of t
                    set tabBusy to busy of t
                    set tabProcs to processes of t
                    set procList to ""
                    repeat with p in tabProcs
                        if procList is not "" then set procList to procList & ","
                        set procList to procList & (p as text)
                    end repeat
                    set output to output & winID & "\\t" & winName & "\\t" & tabIndex & "\\t" & tabName & "\\t" & tabTTY & "\\t" & tabBusy & "\\t" & procList & "\\n"
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

        for line in raw.components(separatedBy: "\n") where !line.isEmpty {
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 7 else { continue }

            let winID = parts[0].trimmingCharacters(in: .whitespaces)
            let winName = parts[1].trimmingCharacters(in: .whitespaces)
            let tabIndex = Int(parts[2].trimmingCharacters(in: .whitespaces)) ?? 0
            let tabName = parts[3].trimmingCharacters(in: .whitespaces)
            let tty = parts[4].trimmingCharacters(in: .whitespaces)
            let busy = parts[5].trimmingCharacters(in: .whitespaces) == "true"
            let processes = parts[6].trimmingCharacters(in: .whitespaces)
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }

            let status = determineStatus(busy: busy, processes: processes)
            let displayTitle = simplifyTitle(tabName)

            let tab = TerminalTab(
                id: "terminal-\(winID)-\(tabIndex)",
                title: displayTitle,
                status: status,
                tty: tty,
                tabIndex: tabIndex - 1  // Convert to 0-based
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
        // Check if Claude Code is running and waiting
        let hasClaude = processes.contains { $0.contains("claude") }
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
        // Terminal.app titles are often like "user@host: ~/path — -zsh"
        // Try to extract the useful part
        var simplified = title

        // Remove "— -zsh", "— bash" etc. from the end
        if let dashRange = simplified.range(of: " — ", options: .backwards) {
            let suffix = String(simplified[dashRange.upperBound...])
            let shells = ["-zsh", "zsh", "-bash", "bash", "fish", "-fish", "login"]
            if shells.contains(suffix.trimmingCharacters(in: .whitespaces)) {
                simplified = String(simplified[..<dashRange.lowerBound])
            }
        }

        // Remove user@host: prefix
        if let colonSpace = simplified.range(of: ": ") {
            simplified = String(simplified[colonSpace.upperBound...])
        }

        // Shorten home directory
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        simplified = simplified.replacingOccurrences(of: home, with: "~")

        return simplified.isEmpty ? title : simplified
    }

    private func simplifyWindowTitle(_ title: String) -> String {
        let simplified = simplifyTitle(title)
        // For window title, just use "Terminal" if it's just a path
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
