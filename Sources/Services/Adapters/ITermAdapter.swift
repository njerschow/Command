import AppKit
import Foundation

/// Scans iTerm2 windows and tabs via AppleScript
final class ITermAdapter {

    private static let delimiter = "|||"
    private let processResolver = ProcessResolver()
    private var hasLoggedPermissionError = false

    func scan() -> [TerminalGroup] {
        guard isRunning() else { return [] }

        let checkScript = "tell application \"iTerm2\" to count windows"
        guard let countStr = runAppleScript(checkScript),
              let count = Int(countStr), count > 0 else {
            if !hasLoggedPermissionError {
                hasLoggedPermissionError = true
                print("[ITermAdapter] Cannot access iTerm2 — check Automation permission")
            }
            return []
        }
        hasLoggedPermissionError = false

        let script = """
        tell application "iTerm2"
            set output to ""
            set lf to (ASCII character 10)
            repeat with w in windows
                set winID to (id of w as text)
                set winName to name of w
                set tabIdx to 0
                repeat with t in tabs of w
                    set tabIdx to tabIdx + 1
                    set s to current session of t
                    set sessionTTY to (tty of s as text)
                    set sessionName to (name of s as text)
                    set isProcessing to (is processing of s as text)
                    set profileName to (profile name of s as text)
                    set output to output & winID & "|||" & winName & "|||" & tabIdx & "|||" & sessionTTY & "|||" & isProcessing & "|||" & sessionName & "|||" & profileName & lf
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
            $0.bundleIdentifier == TerminalApp.iterm.bundleIdentifier
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
            let isProcessing = parts[4].trimmingCharacters(in: .whitespaces) == "true"
            let sessionName = parts[5].trimmingCharacters(in: .whitespaces)

            let processes = tty.isEmpty ? [] : processResolver.allProcessNames(tty: tty)
            let status = determineStatus(isProcessing: isProcessing, processes: processes)
            let title = sessionName.isEmpty ? simplifyTitle(winName) : sessionName

            let tab = TerminalTab(
                id: "iterm-\(winID)-\(tabIndex)",
                title: title,
                status: status,
                tty: tty,
                tabIndex: tabIndex - 1,
                processes: processes
            )

            let key = "iterm-\(winID)"
            if windowMap[key] == nil {
                windowMap[key] = TerminalGroup(
                    id: key,
                    app: .iterm,
                    windowTitle: simplifyTitle(winName),
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

    private func determineStatus(isProcessing: Bool, processes: [String]) -> TerminalStatus {
        let hasClaude = processes.contains { $0.contains("claude") }

        // Claude running but session not processing = Claude finished, waiting for user
        if hasClaude && !isProcessing {
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
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        simplified = simplified.replacingOccurrences(of: home, with: "~")
        return simplified.isEmpty ? "iTerm2" : simplified
    }

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if let error {
            print("[ITermAdapter] AppleScript error: \(error)")
            return nil
        }
        return result?.stringValue
    }
}
