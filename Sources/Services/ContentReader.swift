import Foundation
import AppKit

/// Reads terminal content via AppleScript `history of tab`
final class ContentReader {

    /// Read the last N lines of terminal history
    func readHistory(windowID: Int, tabIndex: Int, app: TerminalApp = .terminal, lineCount: Int = 100) -> String? {
        let asTabIndex = tabIndex + 1  // AppleScript is 1-based

        let script: String
        switch app {
        case .iterm:
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    if id of w is \(windowID) then
                        set s to current session of item \(asTabIndex) of tabs of w
                        return contents of s
                    end if
                end repeat
            end tell
            """
        default:
            script = """
            tell application "Terminal"
                return history of tab \(asTabIndex) of window id \(windowID)
            end tell
            """
        }

        guard let history = runAppleScript(script) else { return nil }
        let lines = history.components(separatedBy: "\n")
        return Array(lines.suffix(lineCount)).joined(separator: "\n")
    }

    /// Resolve the current working directory for a TTY via lsof
    func workingDirectory(tty: String?) -> String? {
        guard let tty, !tty.isEmpty else { return nil }
        // lsof -a -d cwd -c zsh -c bash +D /dev/ttys... is too slow
        // Use the TTY's foreground PID approach instead
        let devName = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "lsof -a -d cwd -c zsh -c bash -c fish 2>/dev/null | grep '\(devName)' | head -1 | awk '{print $NF}'"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let dir = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return (dir?.isEmpty == true) ? nil : dir
        } catch {
            return nil
        }
    }

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }
}
