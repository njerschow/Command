import Foundation
import os

/// Centralized logger for Command app — writes to both os_log and a file for easy debugging
enum Log {
    private static let subsystem = "com.command.app"
    private static let osLog = OSLog(subsystem: subsystem, category: "Command")
    private static let logPath = "/tmp/command-debug.log"
    private static let logQueue = DispatchQueue(label: "com.command.logger", qos: .utility)

    // Truncate on first access (each app launch starts fresh)
    private static let _setup: Void = {
        // Always overwrite to start clean each launch
        try? Data().write(to: URL(fileURLWithPath: logPath), options: .atomic)
    }()

    static func info(_ message: String, category: String = "general") {
        let line = "[\(category)] \(message)"
        os_log("%{public}@", log: osLog, type: .info, line)
        appendToFile(line)
    }

    static func error(_ message: String, category: String = "general") {
        let line = "[ERROR][\(category)] \(message)"
        os_log("%{public}@", log: osLog, type: .error, line)
        appendToFile(line)
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private static func appendToFile(_ line: String) {
        _ = _setup
        let timestamp = dateFormatter.string(from: Date())
        let entry = "\(timestamp) \(line)\n"
        logQueue.async {
            guard let data = entry.data(using: .utf8) else { return }
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            } else {
                // File doesn't exist — create it
                FileManager.default.createFile(atPath: logPath, contents: data)
            }
        }
    }
}
