import Foundation
import Network

/// Lightweight HTTP server that receives Claude Code hook events
/// Claude Code sends POST requests with JSON payloads for events like
/// Stop, Notification, PreToolUse, SessionStart, SessionEnd
final class ClaudeHookServer: ObservableObject {
    private var listener: NWListener?
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.command.claude-hooks", qos: .utility)

    /// Active Claude Code sessions: session_id -> ClaudeSession
    /// Access from main thread only; background work uses pendingSessions + lock
    @Published private(set) var sessions: [String: ClaudeSession] = [:]
    private var pendingSessions: [String: ClaudeSession] = [:]
    private let lock = NSLock()

    init(port: UInt16 = 19220) {
        self.port = port
    }

    // MARK: - Hook Auto-Configuration

    /// Ensure ~/.claude/settings.json has the HTTP hooks Command needs
    func ensureHooksConfigured() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let settingsURL = home.appendingPathComponent(".claude/settings.json")
        let hookURL = "http://localhost:\(port)/claude-event"

        var root: [String: Any]
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            guard let data = try? Data(contentsOf: settingsURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                print("[ClaudeHookServer] Warning: ~/.claude/settings.json exists but could not be parsed, skipping hook configuration")
                return
            }
            root = json
        } else {
            // Create ~/.claude/ if needed
            let claudeDir = home.appendingPathComponent(".claude")
            try? FileManager.default.createDirectory(at: claudeDir, withIntermediateDirectories: true)
            root = [:]
        }

        var hooks = root["hooks"] as? [String: Any] ?? [:]
        let requiredEvents = ["SessionStart", "SessionEnd", "Stop", "Notification", "PreToolUse"]
        let commandHook: [String: Any] = ["type": "http", "url": hookURL]
        var changed = false

        for event in requiredEvents {
            var entries = hooks[event] as? [[String: Any]] ?? []
            // Check if our hook URL is already present in any entry
            let alreadyPresent = entries.contains { entry in
                guard let entryHooks = entry["hooks"] as? [[String: Any]] else { return false }
                return entryHooks.contains { ($0["url"] as? String) == hookURL }
            }
            if !alreadyPresent {
                entries.append(["hooks": [commandHook]])
                hooks[event] = entries
                changed = true
            }
        }

        if changed {
            root["hooks"] = hooks
            if let data = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: settingsURL, options: .atomic)
                print("[ClaudeHookServer] Auto-configured hooks in ~/.claude/settings.json")
            }
        }
    }

    // MARK: - Lifecycle

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            params.requiredLocalEndpoint = NWEndpoint.hostPort(
                host: NWEndpoint.Host("127.0.0.1"),
                port: NWEndpoint.Port(rawValue: port)!
            )
            listener = try NWListener(using: params)
        } catch {
            print("[ClaudeHookServer] Failed to create listener: \(error)")
            return
        }

        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[ClaudeHookServer] Listening on port \(self.port)")
            case .failed(let error):
                print("[ClaudeHookServer] Listener failed: \(error)")
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleConnection(connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection Handling

    private static let maxRequestSize = 1_048_576  // 1 MB

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        var accumulated = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data { accumulated.append(data) }

                if accumulated.count > ClaudeHookServer.maxRequestSize {
                    print("[ClaudeHookServer] Request exceeded \(ClaudeHookServer.maxRequestSize) bytes, dropping connection")
                    connection.cancel()
                    return
                }

                if isComplete || error != nil {
                    self?.processHTTPRequest(accumulated)
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else if let request = String(data: accumulated, encoding: .utf8),
                          self?.isHTTPRequestComplete(request) == true {
                    self?.processHTTPRequest(accumulated)
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{}"
                    connection.send(content: response.data(using: .utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                } else {
                    receiveMore()
                }
            }
        }
        receiveMore()
    }

    private func isHTTPRequestComplete(_ request: String) -> Bool {
        guard let headerEnd = request.range(of: "\r\n\r\n") else { return false }
        let headers = String(request[..<headerEnd.lowerBound]).lowercased()
        if let clRange = headers.range(of: "content-length: ") {
            let clStart = headers[clRange.upperBound...]
            if let clEnd = clStart.firstIndex(of: "\r") ?? clStart.firstIndex(of: "\n"),
               let contentLength = Int(clStart[..<clEnd]) {
                let body = request[headerEnd.upperBound...]
                return body.utf8.count >= contentLength
            }
        }
        return true
    }

    private func processHTTPRequest(_ data: Data) {
        guard let request = String(data: data, encoding: .utf8) else { return }
        let body: String
        if let range = request.range(of: "\r\n\r\n") {
            body = String(request[range.upperBound...])
        } else {
            body = request
        }
        processEvent(body)
    }

    // MARK: - Event Processing

    private func processEvent(_ jsonString: String) {
        guard let data = jsonString.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }

        let sessionID = json["session_id"] as? String ?? "unknown"
        let eventName = json["hook_event_name"] as? String ?? ""
        let cwd = json["cwd"] as? String ?? ""

        lock.lock()

        var session = pendingSessions[sessionID] ?? ClaudeSession(
            sessionID: sessionID, cwd: cwd, state: .working
        )

        switch eventName {
        case "Stop":
            session.state = .waitingForUser
            session.lastEvent = "Finished responding"

        case "Notification":
            if let hookInput = json["hook_input"] as? [String: Any],
               let notificationType = hookInput["notification_type"] as? String {
                switch notificationType {
                case "idle_prompt":
                    session.state = .waitingForUser
                    session.lastEvent = "Waiting for input"
                case "permission_prompt":
                    session.state = .needsPermission
                    session.lastEvent = "Needs permission"
                default:
                    break
                }
            }

        case "PreToolUse":
            session.state = .working
            if let hookInput = json["hook_input"] as? [String: Any],
               let toolName = hookInput["tool_name"] as? String {
                session.lastEvent = "Using \(toolName)"
            }

        case "PostToolUse":
            session.state = .working

        case "SessionStart":
            session.state = .working
            session.lastEvent = "Session started"

        case "SessionEnd":
            pendingSessions.removeValue(forKey: sessionID)
            let snapshot = pendingSessions
            lock.unlock()
            DispatchQueue.main.async { self.sessions = snapshot }
            return

        default:
            break
        }

        session.cwd = cwd
        session.lastUpdated = Date()
        pendingSessions[sessionID] = session
        let snapshot = pendingSessions
        lock.unlock()

        DispatchQueue.main.async { self.sessions = snapshot }
    }

    // MARK: - Discover Existing Sessions

    /// On startup, detect already-running Claude CLI processes and register them
    func discoverExistingSessions() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            guard let psOutput = self.shell("ps -eo pid,args | grep -E '\\bclaude\\b' | grep -v grep | grep -v Claude.app") else { return }

            var discovered: [(sessionID: String, cwd: String)] = []

            for line in psOutput.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // Extract PID (first token)
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                guard let pid = parts.first.flatMap({ Int($0) }) else { continue }

                // Get CWD via lsof
                guard let cwd = self.shell("lsof -a -d cwd -p \(pid) -Fn 2>/dev/null | grep '^n/' | head -1 | sed 's/^n//'")?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !cwd.isEmpty else { continue }

                // Map CWD to Claude project directory
                let encodedPath = cwd.replacingOccurrences(of: "/", with: "-")
                let projectDir = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/projects/\(encodedPath)")

                // Find most recently modified .jsonl = active session
                guard let contents = try? FileManager.default.contentsOfDirectory(
                    at: projectDir, includingPropertiesForKeys: [.contentModificationDateKey]
                ) else { continue }

                let jsonlFiles = contents.filter { $0.pathExtension == "jsonl" }
                let sorted = jsonlFiles.compactMap { url -> (URL, Date)? in
                    guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { return nil }
                    return (url, date)
                }.sorted { $0.1 > $1.1 }

                guard let mostRecent = sorted.first,
                      // Only consider files modified in the last 30 minutes as "active"
                      Date().timeIntervalSince(mostRecent.1) < 1800 else { continue }

                let sessionID = mostRecent.0.deletingPathExtension().lastPathComponent
                discovered.append((sessionID: sessionID, cwd: cwd))
            }

            guard !discovered.isEmpty else { return }

            self.lock.lock()
            for entry in discovered {
                // Don't overwrite sessions already registered via hooks
                if self.pendingSessions[entry.sessionID] == nil {
                    self.pendingSessions[entry.sessionID] = ClaudeSession(
                        sessionID: entry.sessionID,
                        cwd: entry.cwd,
                        state: .waitingForUser
                    )
                }
            }
            let snapshot = self.pendingSessions
            self.lock.unlock()

            DispatchQueue.main.async { self.sessions = snapshot }
            print("[ClaudeHookServer] Discovered \(discovered.count) existing session(s)")
        }
    }

    private func shell(_ command: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Query

    /// Normalize path for comparison (strip trailing slash, resolve symlinks)
    private func normalizePath(_ path: String) -> String {
        var p = path
        while p.hasSuffix("/") && p.count > 1 { p.removeLast() }
        // Resolve symlinks for consistent matching
        let url = URL(fileURLWithPath: p).standardized
        return url.path
    }

    /// Find the most recent Claude session for a given working directory
    func sessionID(forCwd cwd: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        let normalized = normalizePath(cwd)
        return sessions.values
            .filter { normalizePath($0.cwd) == normalized }
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .first?.sessionID
    }

    /// Find Claude session for a given working directory (most recent if multiple)
    func session(forCwd cwd: String) -> ClaudeSession? {
        lock.lock()
        defer { lock.unlock() }
        let normalized = normalizePath(cwd)
        return sessions.values
            .filter { normalizePath($0.cwd) == normalized }
            .sorted { $0.lastUpdated > $1.lastUpdated }
            .first
    }

    /// Check if any session needs attention
    var hasActionRequired: Bool {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.contains {
            $0.state == .waitingForUser || $0.state == .needsPermission
        }
    }
}

// MARK: - Models

struct ClaudeSession {
    let sessionID: String
    var cwd: String
    var state: ClaudeState
    var lastEvent: String = ""
    var lastUpdated: Date = Date()
}

enum ClaudeState: Equatable {
    case working
    case waitingForUser
    case needsPermission
}
