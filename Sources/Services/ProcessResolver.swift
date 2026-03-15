import Foundation

/// Resolves foreground processes for TTY devices using `ps`
final class ProcessResolver {

    struct ProcessInfo {
        let pid: Int
        let tty: String
        let stat: String
        let command: String

        var isForeground: Bool {
            stat.contains("+")
        }

        var isShell: Bool {
            let shells = ["zsh", "-zsh", "bash", "-bash", "fish", "-fish", "login", "sh", "-sh"]
            let base = (command as NSString).lastPathComponent
            return shells.contains(base)
        }
    }

    /// Get the foreground process for a specific TTY
    func foregroundProcess(tty: String) -> ProcessInfo? {
        // Strip /dev/ prefix: /dev/ttys007 → ttys007
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")

        guard let output = shell("ps -t \(ttyShort) -o pid=,tty=,stat=,args=") else {
            return nil
        }

        let processes = parseProcessList(output)
        // Find the foreground process (stat contains '+')
        return processes.first { $0.isForeground && !$0.isShell }
            ?? processes.first { $0.isForeground }
    }

    /// Get all process names for a specific TTY (similar to Terminal.app's `processes of tab`)
    func allProcessNames(tty: String) -> [String] {
        let ttyShort = tty.replacingOccurrences(of: "/dev/", with: "")
        guard !ttyShort.isEmpty,
              let output = shell("ps -t \(ttyShort) -o comm=") else {
            return []
        }
        return output.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .map { ($0 as NSString).lastPathComponent }
    }

    /// Check if a TTY has an idle shell (no foreground non-shell process)
    func isIdle(tty: String) -> Bool {
        guard let fg = foregroundProcess(tty: tty) else { return true }
        return fg.isShell
    }

    private func parseProcessList(_ output: String) -> [ProcessInfo] {
        output.components(separatedBy: "\n").compactMap { line -> ProcessInfo? in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return nil }

            // Format: PID TTY STAT ARGS
            let parts = trimmed.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                .map(String.init)
            guard parts.count >= 4 else { return nil }

            return ProcessInfo(
                pid: Int(parts[0]) ?? 0,
                tty: parts[1],
                stat: parts[2],
                command: parts[3]
            )
        }
    }

    private func shell(_ command: String) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", command]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
