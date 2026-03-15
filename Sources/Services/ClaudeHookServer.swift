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
    @Published private(set) var sessions: [String: ClaudeSession] = [:]
    private let lock = NSLock()

    init(port: UInt16 = 19220) {
        self.port = port
    }

    // MARK: - Lifecycle

    func start() {
        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
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

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        var accumulated = Data()

        func receiveMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
                if let data { accumulated.append(data) }

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

        var session = sessions[sessionID] ?? ClaudeSession(
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
            sessions.removeValue(forKey: sessionID)
            lock.unlock()
            DispatchQueue.main.async { self.objectWillChange.send() }
            return

        default:
            break
        }

        session.cwd = cwd
        session.lastUpdated = Date()

        // Resolve TTY on first event (when tty is not yet known)
        if session.tty == nil {
            session.tty = Self.resolveTTY(forSessionID: sessionID)
        }

        sessions[sessionID] = session
        lock.unlock()

        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    /// Resolve which TTY a Claude session is running on via ps
    private static func resolveTTY(forSessionID sessionID: String) -> String? {
        // Find claude processes and their TTYs
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "ps -eo tty,args 2>/dev/null | grep 'claude' | grep -v grep"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            // Each line: "ttysNNN  /path/to/claude ..."
            // We look for the session ID in the process args, or just return
            // the TTY of any matching claude process
            for line in output.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                // If the session ID appears in the command args, exact match
                if trimmed.contains(sessionID) {
                    let tty = trimmed.components(separatedBy: .whitespaces).first ?? ""
                    if !tty.isEmpty { return "/dev/\(tty)" }
                }
            }

            // Fallback: can't match by session ID in args — return nil
            // (will retry on next event)
            return nil
        } catch {
            return nil
        }
    }

    // MARK: - Query

    /// Find Claude session running on a specific TTY
    func sessionID(forTTY tty: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.first { $0.tty == tty }?.sessionID
    }

    /// Find Claude session for a given working directory
    func session(forCwd cwd: String) -> ClaudeSession? {
        lock.lock()
        defer { lock.unlock() }
        return sessions.values.first { $0.cwd == cwd }
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
    var tty: String?
    var state: ClaudeState
    var lastEvent: String = ""
    var lastUpdated: Date = Date()
}

enum ClaudeState: Equatable {
    case working
    case waitingForUser
    case needsPermission
}
