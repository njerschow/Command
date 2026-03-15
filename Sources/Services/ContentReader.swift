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

    /// Resolve the current working directory for a TTY
    /// Strategy: find the shell PID on the TTY via `ps`, then get its CWD via `lsof`
    func workingDirectory(tty: String?) -> String? {
        guard let tty, !tty.isEmpty else { return nil }
        let devName = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty

        // Step 1: find the shell PID on this TTY
        guard let shellPID = findShellPID(tty: devName) else { return nil }

        // Step 2: get the CWD of that PID
        return cwdForPID(shellPID)
    }

    private func findShellPID(tty: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-t", tty, "-o", "pid=,comm="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            // Find a shell process (zsh, bash, fish)
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains("zsh") || trimmed.contains("bash") || trimmed.contains("fish") {
                    return trimmed.components(separatedBy: .whitespaces).first(where: { !$0.isEmpty })
                }
            }
            return nil
        } catch {
            return nil
        }
    }

    private func cwdForPID(_ pid: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-a", "-d", "cwd", "-p", pid, "-Fn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }
            // -Fn outputs lines like "n/path/to/dir"
            for line in output.components(separatedBy: "\n") {
                if line.hasPrefix("n/") {
                    let dir = String(line.dropFirst(1))
                    return dir.isEmpty ? nil : dir
                }
            }
            return nil
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
