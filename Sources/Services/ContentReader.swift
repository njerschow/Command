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

    /// Authoritative save-time lookup: fresh TTY-based resolution of directory and Claude session ID.
    /// Unlike cached values, this queries the OS directly at the moment of save.
    func authoritativeLookup(tty: String?, isClaudeSession: Bool,
                             excludingSessionIDs: Set<String> = []) -> (dir: String, sessionID: String?)? {
        guard let tty, !tty.isEmpty else { return nil }
        let devName = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty

        // Get the REAL directory from the shell process on this TTY
        guard let shellPID = findShellPID(tty: devName) else {
            Log.info("authoritativeLookup: no shell PID for tty=\(devName)", category: "save")
            return nil
        }
        guard let dir = cwdForPID(shellPID) else {
            Log.info("authoritativeLookup: no CWD for pid=\(shellPID)", category: "save")
            return nil
        }

        // Get the REAL Claude session ID
        var sessionID: String? = nil
        if isClaudeSession {
            // Most reliable: extract --resume arg directly from process args
            // This is the EXACT session ID Claude uses in hooks — no file correlation needed
            if let claudePID = findProcessPID(named: "claude", tty: devName),
               let args = processArgs(pid: claudePID) {
                if let resumeIdx = args.firstIndex(of: "--resume"), resumeIdx + 1 < args.count {
                    let sid = args[resumeIdx + 1]
                    let isSafe = sid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                    if isSafe && !sid.isEmpty {
                        sessionID = sid
                        Log.info("authoritativeLookup: tty=\(devName) dir=\(dir) sid=\(sid.prefix(8)) (from --resume arg)", category: "save")
                    }
                }
            }
            // Fallback: full file-based discovery (for fresh sessions without --resume)
            if sessionID == nil {
                if let result = discoverClaudeSession(tty: tty, excluding: excludingSessionIDs) {
                    sessionID = result.sessionID
                    Log.info("authoritativeLookup: tty=\(devName) dir=\(dir) sid=\(sessionID!.prefix(8)) (from file discovery)", category: "save")
                } else {
                    Log.info("authoritativeLookup: tty=\(devName) dir=\(dir) no Claude session found", category: "save")
                }
            }
        } else {
            Log.info("authoritativeLookup: tty=\(devName) dir=\(dir) (not Claude)", category: "save")
        }

        return (dir: dir, sessionID: sessionID)
    }

    /// Discover the Claude session ID and project CWD for a claude process on a TTY.
    /// Strategy (in order):
    ///   1. Check `--resume <id>` in process args → direct match
    ///   2. Search .claude/projects/ for session files, correlate by creation time ↔ process start time
    func discoverClaudeSession(tty: String?, excluding assignedIDs: Set<String>) -> (sessionID: String, projectCwd: String)? {
        guard let tty, !tty.isEmpty else { return nil }
        let devName = tty.hasPrefix("/dev/") ? String(tty.dropFirst(5)) : tty
        guard let pid = findProcessPID(named: "claude", tty: devName) else { return nil }

        // Strategy 1: extract session ID from --resume argument
        if let args = processArgs(pid: pid) {
            if let resumeIdx = args.firstIndex(of: "--resume"), resumeIdx + 1 < args.count {
                let sid = args[resumeIdx + 1]
                let isSafe = sid.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
                if isSafe && !sid.isEmpty && !assignedIDs.contains(sid) {
                    // Find the project CWD from the session file
                    if let projectCwd = projectCwdForSession(sid) {
                        return (sessionID: sid, projectCwd: projectCwd)
                    }
                }
            }
        }

        // Strategy 2: correlate session file creation time with process start time
        let startTime = processStartTime(pid: pid)

        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return nil }

        struct Candidate {
            let sessionID: String
            let projectCwd: String
            let creationTime: Date
            let mtime: Date
        }
        var candidates: [Candidate] = []

        for dir in projectDirs where dir.hasDirectoryPath {
            guard let files = try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .creationDateKey]
            ) else { continue }

            for file in files where file.pathExtension == "jsonl" {
                guard let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .creationDateKey, .fileSizeKey]),
                      let mtime = values.contentModificationDate,
                      Date().timeIntervalSince(mtime) < 1800 else { continue }

                // Skip internal CLI artifacts (queue-operation, etc.) — real sessions are much larger
                let fileSize = values.fileSize ?? 0
                if fileSize < 50_000 { continue }

                // Must be modified after process started
                if let startTime, mtime < startTime { continue }

                let sid = file.deletingPathExtension().lastPathComponent
                if assignedIDs.contains(sid) { continue }

                let encoded = dir.lastPathComponent
                let decoded = encoded.replacingOccurrences(of: "-", with: "/")
                let projectCwd = decoded.hasPrefix("/") ? decoded : "/" + decoded

                let creationTime = values.creationDate ?? mtime
                candidates.append(Candidate(sessionID: sid, projectCwd: projectCwd, creationTime: creationTime, mtime: mtime))
            }
        }

        guard !candidates.isEmpty else { return nil }

        // If we have a process start time, prefer the session whose creation time
        // is closest to the process start (disambiguates multiple sessions in same dir)
        if let startTime {
            let sorted = candidates.sorted {
                abs($0.creationTime.timeIntervalSince(startTime)) < abs($1.creationTime.timeIntervalSince(startTime))
            }
            if let best = sorted.first {
                return (sessionID: best.sessionID, projectCwd: best.projectCwd)
            }
        }

        // Fallback: most recently modified
        return candidates.sorted(by: { $0.mtime > $1.mtime }).first.map { ($0.sessionID, $0.projectCwd) }
    }

    /// Find the project CWD for a known session ID by searching project directories
    private func projectCwdForSession(_ sessionID: String) -> String? {
        let projectsDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(
            at: projectsDir, includingPropertiesForKeys: nil
        ) else { return nil }
        for dir in projectDirs where dir.hasDirectoryPath {
            let file = dir.appendingPathComponent("\(sessionID).jsonl")
            if FileManager.default.fileExists(atPath: file.path) {
                let encoded = dir.lastPathComponent
                let decoded = encoded.replacingOccurrences(of: "-", with: "/")
                return decoded.hasPrefix("/") ? decoded : "/" + decoded
            }
        }
        return nil
    }

    private func processArgs(pid: String) -> [String]? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pid, "-o", "args="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            return output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        } catch {
            return nil
        }
    }

    private func processStartTime(pid: String) -> Date? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", pid, "-o", "lstart="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !output.isEmpty else { return nil }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM dd HH:mm:ss yyyy"
            return formatter.date(from: output)
        } catch {
            return nil
        }
    }

    private func findProcessPID(named name: String, tty: String) -> String? {
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
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasSuffix(name) || trimmed.contains("/\(name)") {
                    return trimmed.components(separatedBy: .whitespaces).first(where: { !$0.isEmpty })
                }
            }
            return nil
        } catch {
            return nil
        }
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
