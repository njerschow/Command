import Foundation
import Combine

/// Manages autopilot mode for Claude Code sessions — automatically generates
/// the next user message when Claude is waiting for input
final class AutopilotManager: ObservableObject {

    // MARK: - Types

    enum SessionState: Equatable {
        case idle           // Autopilot enabled, Claude is working
        case thinking       // Brain subprocess running
        case injecting      // Sending keystroke
        case escalated(String)  // Needs human attention
    }

    struct Session {
        let tabID: String
        let claudeSessionID: String
        var group: TerminalGroup
        var tab: TerminalTab
        var state: SessionState = .idle
        var cycleCount: Int = 0
        var lastCycleTime: Date?
    }

    // MARK: - Published State

    @Published var sessions: [String: Session] = [:]  // keyed by tab ID

    // MARK: - Private

    private var cancellables = Set<AnyCancellable>()
    private weak var hookServer: ClaudeHookServer?
    private weak var sessionStore: SessionStore?
    private let brainQueue = DispatchQueue(label: "com.command.autopilot-brain", qos: .userInitiated)
    private var runningProcesses: [String: Process] = [:]  // tabID -> brain process
    private let maxCycles = 100
    private let cooldownSeconds: TimeInterval = 3

    // MARK: - Lifecycle

    func start(hookServer: ClaudeHookServer, sessionStore: SessionStore) {
        self.hookServer = hookServer
        self.sessionStore = sessionStore

        // Observe hook session state changes
        hookServer.$sessions
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hookSessions in
                self?.handleStateUpdates(hookSessions)
            }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        for (_, process) in runningProcesses {
            process.terminate()
        }
        runningProcesses.removeAll()
        sessions.removeAll()
    }

    // MARK: - Enable/Disable (keyed by tab ID)

    func enable(tabID: String, claudeSessionID: String, group: TerminalGroup, tab: TerminalTab) {
        let session = Session(
            tabID: tabID,
            claudeSessionID: claudeSessionID,
            group: group,
            tab: tab
        )
        sessions[tabID] = session
        Log.info("autopilot ENABLED tab=\(tabID) sid=\(claudeSessionID.prefix(8))", category: "autopilot")

        // If already waiting for input, start immediately
        if let hookSession = hookServer?.sessions[claudeSessionID],
           hookSession.state == .waitingForUser {
            triggerCycle(tabID: tabID)
        }
    }

    func disable(tabID: String) {
        if let process = runningProcesses[tabID], process.isRunning {
            process.terminate()
            runningProcesses.removeValue(forKey: tabID)
        }
        sessions.removeValue(forKey: tabID)
        Log.info("autopilot DISABLED tab=\(tabID)", category: "autopilot")
    }

    func isEnabled(tabID: String) -> Bool {
        sessions[tabID] != nil
    }

    func sessionState(tabID: String) -> SessionState? {
        sessions[tabID]?.state
    }

    func dismissEscalation(tabID: String) {
        sessions[tabID]?.state = .idle
    }

    // MARK: - State Observation

    private func handleStateUpdates(_ hookSessions: [String: ClaudeSession]) {
        for (tabID, apSession) in sessions {
            guard let hookSession = hookSessions[apSession.claudeSessionID] else { continue }

            // Auto-approve permission prompts immediately
            if hookSession.state == .needsPermission && apSession.state == .idle {
                Log.info("autopilot: auto-approving permission for tab=\(tabID)", category: "autopilot")
                approvePermission(tabID: tabID)
                continue
            }

            // Trigger brain cycle when waiting for user input
            if hookSession.state == .waitingForUser && apSession.state == .idle {
                if let last = apSession.lastCycleTime,
                   Date().timeIntervalSince(last) < cooldownSeconds {
                    continue
                }
                triggerCycle(tabID: tabID)
            }

            // If Claude starts working again, reset to idle — but respect certain states
            if hookSession.state == .working {
                switch apSession.state {
                case .thinking:
                    // User typed before autopilot could inject — discard brain result
                    sessions[tabID]?.state = .idle
                case .escalated:
                    // Keep escalated — user must dismiss manually
                    break
                case .injecting:
                    // Keep injecting — let the 1s timer finish
                    break
                case .idle:
                    break
                }
            }
        }
    }

    // MARK: - Autopilot Cycle

    private func triggerCycle(tabID: String) {
        guard var session = sessions[tabID] else { return }

        if session.cycleCount >= maxCycles {
            session.state = .escalated("Reached \(maxCycles) autopilot cycles — pausing for human review.")
            sessions[tabID] = session
            return
        }

        session.state = .thinking
        session.lastCycleTime = Date()
        sessions[tabID] = session

        let sid = session.claudeSessionID
        let cwd = hookServer?.sessions[sid]?.cwd ?? ""
        let cycleCount = session.cycleCount

        Log.info("autopilot cycle #\(cycleCount + 1) for tab=\(tabID) sid=\(sid.prefix(8)) cwd=\(cwd)", category: "autopilot")

        brainQueue.async { [weak self] in
            guard let self else { return }

            // Read conversation history
            let turns = ConversationReader.readHistory(sessionID: sid, cwd: cwd)
            Log.info("autopilot: read \(turns.count) turns from JSONL", category: "autopilot")

            let history = ConversationReader.formatForPrompt(turns)

            if history.isEmpty {
                DispatchQueue.main.async {
                    self.sessions[tabID]?.state = .escalated("Could not read conversation history.")
                }
                return
            }

            Log.info("autopilot: prompt size \(history.count) chars, calling brain...", category: "autopilot")

            let prompt = self.buildBrainPrompt(history: history, cwd: cwd, cycleCount: cycleCount)
            let decision = self.callBrain(prompt: prompt, tabID: tabID)

            DispatchQueue.main.async {
                guard self.sessions[tabID] != nil else { return }

                // Check if Claude went back to working
                if let hookState = self.hookServer?.sessions[sid]?.state,
                   hookState == .working {
                    self.sessions[tabID]?.state = .idle
                    Log.info("autopilot: Claude working during thinking, skipping", category: "autopilot")
                    return
                }

                switch decision {
                case .send(let message):
                    self.injectMessage(message, tabID: tabID)
                case .escalate(let reason):
                    self.sessions[tabID]?.state = .escalated(reason)
                    Log.info("autopilot ESCALATED: \(reason)", category: "autopilot")
                case .error(let msg):
                    self.sessions[tabID]?.state = .escalated("Error: \(msg)")
                    Log.error("autopilot error: \(msg)", category: "autopilot")
                }
            }
        }
    }

    // MARK: - Brain

    private enum Decision {
        case send(String)
        case escalate(String)
        case error(String)
    }

    private func buildBrainPrompt(history: String, cwd: String, cycleCount: Int) -> String {
        """
        You are an autopilot agent supervising a Claude Code session. Your job is to decide what message to send next to keep the session productive, or escalate to the human if needed.

        ## Project Context
        Working directory: \(cwd)
        Autopilot cycle: \(cycleCount + 1)

        ## Conversation History
        \(history)

        ## Rules
        1. If Claude just completed a task successfully, give it the next logical step or ask it to verify/test its work.
        2. If Claude asked a question, answer it based on conversation context. If you genuinely cannot answer, escalate.
        3. If Claude reported an error, instruct it to try a different approach or debug the issue.
        4. If Claude seems stuck in a loop (repeating similar actions), escalate to the human.
        5. If the original task appears complete with nothing left to do, escalate with a summary of what was accomplished.
        6. Keep messages concise and actionable — 1-3 sentences.
        7. Never instruct Claude to do anything destructive (delete repos, force push, drop databases) without escalating first.
        8. If Claude is asking for permission or confirmation about something potentially dangerous, escalate.

        ## Response Format
        Respond with EXACTLY one of these two formats (no other text):
        SEND: <your message to send to Claude Code>
        ESCALATE: <reason to show the human>
        """
    }

    private func callBrain(prompt: String, tabID: String) -> Decision {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "CLAUDECODE= claude -p --model sonnet --no-session-persistence"]

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            runningProcesses[tabID] = process

            inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
            inputPipe.fileHandleForWriting.closeFile()

            var outputData = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global().async {
                outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            let exitGroup = DispatchGroup()
            exitGroup.enter()
            DispatchQueue.global().async { process.waitUntilExit(); exitGroup.leave() }
            if exitGroup.wait(timeout: .now() + 90) == .timedOut {
                process.terminate()
                runningProcesses.removeValue(forKey: tabID)
                return .escalate("Autopilot brain timed out (90s).")
            }

            readGroup.wait()
            runningProcesses.removeValue(forKey: tabID)

            guard let response = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !response.isEmpty else {
                return .error("Brain returned empty response")
            }

            Log.info("autopilot brain response: \(response.prefix(120))", category: "autopilot")
            return parseDecision(response)
        } catch {
            runningProcesses.removeValue(forKey: tabID)
            return .error(error.localizedDescription)
        }
    }

    private func parseDecision(_ response: String) -> Decision {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        for line in trimmed.components(separatedBy: "\n") {
            let l = line.trimmingCharacters(in: .whitespaces)
            if l.uppercased().hasPrefix("SEND:") {
                let message = String(l.dropFirst(5)).trimmingCharacters(in: .whitespaces)
                if !message.isEmpty { return .send(message) }
            }
            if l.uppercased().hasPrefix("ESCALATE:") {
                let reason = String(l.dropFirst(9)).trimmingCharacters(in: .whitespaces)
                if !reason.isEmpty { return .escalate(reason) }
            }
        }

        // If response doesn't follow format, treat as message if short enough
        if trimmed.count < 500 {
            return .send(trimmed)
        }
        return .escalate("Autopilot brain returned unexpected format")
    }

    // MARK: - Permission Auto-Approval

    private func approvePermission(tabID: String) {
        guard let session = sessions[tabID] else { return }
        WindowFocuser.shared.injectText("y", group: session.group, tab: session.tab)
    }

    // MARK: - Injection

    private func injectMessage(_ message: String, tabID: String) {
        guard var session = sessions[tabID] else { return }
        session.state = .injecting
        session.cycleCount += 1
        sessions[tabID] = session

        Log.info("autopilot INJECTING (cycle \(session.cycleCount)): \(message.prefix(80))", category: "autopilot")

        WindowFocuser.shared.injectText(message, group: session.group, tab: session.tab)

        // Reset to idle after injection — next hook event will trigger the next cycle
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            if self.sessions[tabID]?.state == .injecting {
                self.sessions[tabID]?.state = .idle
            }
        }
    }
}
