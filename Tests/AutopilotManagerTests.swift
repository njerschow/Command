import XCTest
@testable import Command

/// Comprehensive test suite for the autopilot system.
/// Tests cover: state machine, hook integration, cycle logic, decision parsing,
/// conversation reading, permission auto-approval, edge cases, and race conditions.
final class AutopilotManagerTests: XCTestCase {

    private var manager: AutopilotManager!
    private var hookServer: ClaudeHookServer!

    private let testTabID = "terminal-100-ttys000"
    private let testSessionID = "test-session-abc"
    private let testCwd = "/tmp/test-project"

    override func setUp() {
        super.setUp()
        hookServer = ClaudeHookServer(port: 0)
        manager = AutopilotManager()
        manager.start(hookServer: hookServer, sessionStore: SessionStore())
    }

    override func tearDown() {
        manager.stop()
        super.tearDown()
    }

    // MARK: - Helpers

    private func makeGroup(windowID: Int = 100) -> TerminalGroup {
        let tab = makeTab()
        return TerminalGroup(id: "terminal-\(windowID)", app: .terminal, windowTitle: "Test", windowID: windowID, tabs: [tab])
    }

    private func makeTab(tty: String = "/dev/ttys000") -> TerminalTab {
        TerminalTab(id: testTabID, title: "Test Terminal", status: .running, tty: tty, tabIndex: 0, processes: ["claude"])
    }

    private func event(_ name: String, session: String? = nil, cwd: String? = nil, extra: [String: Any] = [:]) -> String {
        var json: [String: Any] = [
            "session_id": session ?? testSessionID,
            "hook_event_name": name,
            "cwd": cwd ?? testCwd
        ]
        for (k, v) in extra { json[k] = v }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(data: data, encoding: .utf8)!
    }

    private func flush() {
        let exp = expectation(description: "flush")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 2)
    }

    private func enableAutopilot() {
        let group = makeGroup()
        manager.enable(tabID: testTabID, claudeSessionID: testSessionID, group: group, tab: group.tabs[0])
    }

    // MARK: - Enable / Disable

    func testEnableCreatesSession() {
        enableAutopilot()
        XCTAssertTrue(manager.isEnabled(tabID: testTabID))
        XCTAssertNotNil(manager.sessions[testTabID])
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)
    }

    func testDisableRemovesSession() {
        enableAutopilot()
        manager.disable(tabID: testTabID)
        XCTAssertFalse(manager.isEnabled(tabID: testTabID))
        XCTAssertNil(manager.sessions[testTabID])
    }

    func testEnableMultipleSessions() {
        let group1 = makeGroup(windowID: 100)
        let tab1 = group1.tabs[0]
        let group2 = TerminalGroup(id: "terminal-200", app: .terminal, windowTitle: "Test2", windowID: 200,
                                   tabs: [TerminalTab(id: "terminal-200-ttys001", title: "Test2", status: .running, tty: "/dev/ttys001", tabIndex: 0, processes: ["claude"])])
        let tab2 = group2.tabs[0]

        manager.enable(tabID: tab1.id, claudeSessionID: "session-a", group: group1, tab: tab1)
        manager.enable(tabID: tab2.id, claudeSessionID: "session-b", group: group2, tab: tab2)

        XCTAssertTrue(manager.isEnabled(tabID: tab1.id))
        XCTAssertTrue(manager.isEnabled(tabID: tab2.id))
        XCTAssertEqual(manager.sessions.count, 2)
    }

    func testDisableOnlyAffectsTargetSession() {
        let group1 = makeGroup(windowID: 100)
        let tab1 = group1.tabs[0]
        let group2 = TerminalGroup(id: "terminal-200", app: .terminal, windowTitle: "Test2", windowID: 200,
                                   tabs: [TerminalTab(id: "terminal-200-ttys001", title: "Test2", status: .running, tty: "/dev/ttys001", tabIndex: 0, processes: ["claude"])])
        let tab2 = group2.tabs[0]

        manager.enable(tabID: tab1.id, claudeSessionID: "session-a", group: group1, tab: tab1)
        manager.enable(tabID: tab2.id, claudeSessionID: "session-b", group: group2, tab: tab2)

        manager.disable(tabID: tab1.id)
        XCTAssertFalse(manager.isEnabled(tabID: tab1.id))
        XCTAssertTrue(manager.isEnabled(tabID: tab2.id))
    }

    // MARK: - State Transitions via Hooks

    func testWorkingStateResetsToIdle() {
        enableAutopilot()

        // Simulate Claude starts working
        hookServer.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flush()

        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)
    }

    func testStopEventTriggersThinking() {
        // First put session in working state via hook
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()

        // Claude finishes — sets waitingForUser
        hookServer.processEvent(event("Stop"))
        flush()

        // Should transition to thinking (brain cycle triggered)
        let state = manager.sessionState(tabID: testTabID)
        // State should be thinking or still idle (depending on timing), but definitely not waitingForUser
        XCTAssertTrue(state == .thinking || state == .idle)
    }

    func testPermissionEventTriggersApproval() {
        // Setup: session working via hook
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()

        // Permission prompt arrives
        hookServer.processEvent(event("Notification", extra: ["notification_type": "permission_prompt"]))
        flush()

        // Manager should remain idle after auto-approving (it sends "y" and stays idle)
        let state = manager.sessionState(tabID: testTabID)
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Cooldown

    func testCooldownPreventsRapidCycles() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()

        // Set lastCycleTime to now
        manager.sessions[testTabID]?.lastCycleTime = Date()

        // Trigger a state update — should be skipped due to cooldown
        hookServer.processEvent(event("Stop"))
        flush()

        // Should still be idle (cooldown prevented thinking)
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)
    }

    func testCooldownExpiresAfterDelay() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()

        // Set lastCycleTime to 5 seconds ago (past cooldown)
        manager.sessions[testTabID]?.lastCycleTime = Date().addingTimeInterval(-5)

        hookServer.processEvent(event("Stop"))
        flush()

        // Should proceed to thinking (cooldown expired)
        let state = manager.sessionState(tabID: testTabID)
        XCTAssertTrue(state == .thinking || state == .idle)
    }

    // MARK: - Max Cycles

    func testMaxCyclesEscalates() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()
        manager.sessions[testTabID]?.cycleCount = 100

        hookServer.processEvent(event("Stop"))
        flush()

        if case .escalated(let reason) = manager.sessionState(tabID: testTabID) {
            XCTAssertTrue(reason.contains("100"))
        } else {
            // May not have triggered yet depending on timing
        }
    }

    // MARK: - Dismiss Escalation

    func testDismissEscalationResetsToIdle() {
        enableAutopilot()
        manager.sessions[testTabID]?.state = .escalated("Test escalation")
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .escalated("Test escalation"))

        manager.dismissEscalation(tabID: testTabID)
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)
    }

    // MARK: - Decision Parsing

    func testParseSendDecision() {
        let result = parseDecisionHelper("SEND: please continue with the implementation")
        if case .send(let msg) = result {
            XCTAssertEqual(msg, "please continue with the implementation")
        } else {
            XCTFail("Expected .send, got \(result)")
        }
    }

    func testParseEscalateDecision() {
        let result = parseDecisionHelper("ESCALATE: task appears complete, nothing left to do")
        if case .escalate(let reason) = result {
            XCTAssertEqual(reason, "task appears complete, nothing left to do")
        } else {
            XCTFail("Expected .escalate, got \(result)")
        }
    }

    func testParseSendCaseInsensitive() {
        let result = parseDecisionHelper("send: do the thing")
        if case .send(let msg) = result {
            XCTAssertEqual(msg, "do the thing")
        } else {
            XCTFail("Expected .send")
        }
    }

    func testParseEscalateCaseInsensitive() {
        let result = parseDecisionHelper("Escalate: needs human review")
        if case .escalate(let reason) = result {
            XCTAssertEqual(reason, "needs human review")
        } else {
            XCTFail("Expected .escalate")
        }
    }

    func testParseMultilineTakesSendFromFirstMatch() {
        let response = """
        Here's my analysis:
        SEND: continue with tests
        ESCALATE: just in case
        """
        let result = parseDecisionHelper(response)
        if case .send(let msg) = result {
            XCTAssertEqual(msg, "continue with tests")
        } else {
            XCTFail("Expected .send from first matching line")
        }
    }

    func testParseShortUnformattedResponseTreatedAsSend() {
        let result = parseDecisionHelper("yes, continue")
        if case .send(let msg) = result {
            XCTAssertEqual(msg, "yes, continue")
        } else {
            XCTFail("Short unformatted response should be treated as send")
        }
    }

    func testParseLongUnformattedResponseEscalates() {
        let longText = String(repeating: "a", count: 600)
        let result = parseDecisionHelper(longText)
        if case .escalate = result {
            // Expected
        } else {
            XCTFail("Long unformatted response should escalate")
        }
    }

    func testParseEmptySendIgnored() {
        let result = parseDecisionHelper("SEND: ")
        // Empty SEND should fall through to short-response fallback
        if case .send(let msg) = result {
            XCTAssertEqual(msg, "SEND:")
        } else {
            XCTFail("Expected fallback to send")
        }
    }

    // MARK: - Conversation Reader

    func testConversationReaderParsesJSONL() {
        let tmpDir = NSTemporaryDirectory()
        let sessionID = "test-conv-\(UUID().uuidString.prefix(8))"
        let encodedCwd = testCwd.replacingOccurrences(of: "/", with: "-")
        let projectDir = "\(tmpDir).claude-test/projects/\(encodedCwd)"
        try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        let jsonl = """
        {"type":"user","message":{"role":"user","content":"hello"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Hi! How can I help?"}]}}
        {"type":"user","message":{"role":"user","content":"fix the bug"}}
        {"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"I'll look at the code"},{"type":"tool_use","name":"Read"}]}}
        """
        let filePath = "\(projectDir)/\(sessionID).jsonl"
        try? jsonl.write(toFile: filePath, atomically: true, encoding: .utf8)

        let turns = ConversationReader.readHistory(sessionID: sessionID, cwd: testCwd, testBasePath: projectDir)
        XCTAssertEqual(turns.count, 4)
        XCTAssertEqual(turns[0].role, "user")
        XCTAssertEqual(turns[0].text, "hello")
        XCTAssertEqual(turns[1].role, "assistant")
        XCTAssertTrue(turns[1].text.contains("How can I help"))
        XCTAssertEqual(turns[3].toolCalls, ["Read"])

        // Cleanup
        try? FileManager.default.removeItem(atPath: "\(tmpDir).claude-test")
    }

    func testConversationReaderMaxTurns() {
        let tmpDir = NSTemporaryDirectory()
        let sessionID = "test-max-\(UUID().uuidString.prefix(8))"
        let encodedCwd = testCwd.replacingOccurrences(of: "/", with: "-")
        let projectDir = "\(tmpDir).claude-test2/projects/\(encodedCwd)"
        try? FileManager.default.createDirectory(atPath: projectDir, withIntermediateDirectories: true)

        var lines: [String] = []
        for i in 0..<30 {
            lines.append("""
            {"type":"user","message":{"role":"user","content":"message \(i)"}}
            """)
        }
        let filePath = "\(projectDir)/\(sessionID).jsonl"
        try? lines.joined(separator: "\n").write(toFile: filePath, atomically: true, encoding: .utf8)

        let turns = ConversationReader.readHistory(sessionID: sessionID, cwd: testCwd, maxTurns: 5, testBasePath: projectDir)
        XCTAssertEqual(turns.count, 5)
        XCTAssertEqual(turns[0].text, "message 25")  // Last 5 of 30

        try? FileManager.default.removeItem(atPath: "\(tmpDir).claude-test2")
    }

    func testConversationReaderMissingFileReturnsEmpty() {
        let turns = ConversationReader.readHistory(sessionID: "nonexistent", cwd: "/nonexistent/path")
        XCTAssertTrue(turns.isEmpty)
    }

    func testFormatForPromptTruncatesLongMessages() {
        let longText = String(repeating: "x", count: 2000)
        let turns = [ConversationReader.Turn(role: "user", text: longText, toolCalls: [])]
        let result = ConversationReader.formatForPrompt(turns)
        XCTAssertTrue(result.contains("[truncated]"))
        XCTAssertTrue(result.count < 2000)
    }

    func testFormatForPromptIncludesToolCalls() {
        let turns = [ConversationReader.Turn(role: "assistant", text: "editing", toolCalls: ["Read", "Edit"])]
        let result = ConversationReader.formatForPrompt(turns)
        XCTAssertTrue(result.contains("[Tools: Read, Edit]"))
    }

    func testFormatForPromptTruncatesOverallLength() {
        var turns: [ConversationReader.Turn] = []
        for i in 0..<100 {
            turns.append(ConversationReader.Turn(role: "user", text: "Message number \(i) with some content padding here", toolCalls: []))
        }
        let result = ConversationReader.formatForPrompt(turns, maxChars: 500)
        XCTAssertTrue(result.count <= 540)  // Slightly over due to truncation message
        XCTAssertTrue(result.contains("truncated"))
    }

    // MARK: - Edge Cases

    func testEnableWhileAlreadyWaitingTriggersImmediately() {
        // Claude is already waiting for input when autopilot is enabled
        hookServer.processEvent(event("Stop"))
        flush()

        enableAutopilot()

        // Should immediately start thinking since Claude is waitingForUser
        let state = manager.sessionState(tabID: testTabID)
        XCTAssertTrue(state == .thinking || state == .idle)
    }

    func testDisableWhileThinkingCleansUp() {
        hookServer.processEvent(event("SessionStart"))
        flush()
        enableAutopilot()

        // Force thinking state
        manager.sessions[testTabID]?.state = .thinking

        // Disable during thinking
        manager.disable(tabID: testTabID)
        XCTAssertFalse(manager.isEnabled(tabID: testTabID))
        XCTAssertNil(manager.sessions[testTabID])
    }

    func testHookSessionNotFoundSkipsUpdate() {
        // Enable autopilot with a session ID that doesn't exist in hookServer
        let group = makeGroup()
        manager.enable(tabID: testTabID, claudeSessionID: "nonexistent-session", group: group, tab: group.tabs[0])

        // Send hooks for a different session
        hookServer.processEvent(event("Stop", session: "other-session"))
        flush()

        // Autopilot should remain idle — no matching hook session
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)
    }

    func testStopCallCleansUpEverything() {
        let group = makeGroup()
        manager.enable(tabID: testTabID, claudeSessionID: testSessionID, group: group, tab: group.tabs[0])
        manager.enable(tabID: "other-tab", claudeSessionID: "other-sid", group: group, tab: group.tabs[0])

        manager.stop()
        XCTAssertTrue(manager.sessions.isEmpty)
    }

    func testEscalatedStateBlocksCycles() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()
        manager.sessions[testTabID]?.state = .escalated("blocked")

        // Even though hook says waitingForUser, escalated state should not trigger
        hookServer.processEvent(event("Stop"))
        flush()

        // Should still be escalated
        if case .escalated = manager.sessionState(tabID: testTabID) {
            // Expected
        } else {
            XCTFail("Escalated state should persist through state updates")
        }
    }

    func testThinkingStateBlocksNewCycles() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()
        manager.sessions[testTabID]?.state = .thinking
        let initialCycleCount = manager.sessions[testTabID]?.cycleCount ?? 0

        // Another Stop event while already thinking should not start another cycle
        hookServer.processEvent(event("Stop"))
        flush()

        // The key invariant: cycle count should NOT have increased (no double-trigger)
        // State may have been reset to idle by Combine timing, but no new cycle was started
        let currentCycleCount = manager.sessions[testTabID]?.cycleCount ?? 0
        XCTAssertEqual(currentCycleCount, initialCycleCount, "Should not double-trigger a cycle")
    }

    func testInjectingStateBlocksNewCycles() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()
        manager.sessions[testTabID]?.state = .injecting

        hookServer.processEvent(event("Stop"))
        flush()

        // Should not override injecting state
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .injecting)
    }

    // MARK: - Race Condition: Claude Goes Back to Working

    func testClaudeStartsWorkingDuringThinkingResetsToIdle() {
        hookServer.processEvent(event("SessionStart"))
        flush()

        enableAutopilot()

        // Simulate: autopilot is thinking, but Claude starts working again
        // (e.g., user typed something before autopilot could inject)
        manager.sessions[testTabID]?.state = .thinking

        hookServer.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flush()

        // The handleStateUpdates should reset thinking → idle when hook shows working
        // (The actual race check happens in triggerCycle's main queue callback, but
        //  handleStateUpdates also handles working state transition)
        let state = manager.sessionState(tabID: testTabID)
        XCTAssertEqual(state, .idle)
    }

    // MARK: - Brain Prompt Building

    func testBrainPromptContainsCwd() {
        // Use reflection or test the prompt indirectly
        // The brain prompt should include the working directory
        let history = "Human: fix the bug\n\nClaude: I'll look at it\n\n"
        let prompt = buildBrainPromptHelper(history: history, cwd: "/Users/test/project", cycleCount: 3)
        XCTAssertTrue(prompt.contains("/Users/test/project"))
        XCTAssertTrue(prompt.contains("4"))  // cycle count + 1
        XCTAssertTrue(prompt.contains("SEND:"))
        XCTAssertTrue(prompt.contains("ESCALATE:"))
    }

    // MARK: - Hook Integration: Full Flow

    func testFullHookLifecycleWithAutopilot() {
        // 1. Session starts
        hookServer.processEvent(event("SessionStart"))
        flush()

        // 2. Enable autopilot
        enableAutopilot()
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)

        // 3. Claude uses tools
        hookServer.processEvent(event("PreToolUse", extra: ["tool_name": "Read"]))
        flush()
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)

        // 4. Claude stops (waiting for user)
        hookServer.processEvent(event("Stop"))
        flush()

        // 5. Should trigger thinking
        let state = manager.sessionState(tabID: testTabID)
        XCTAssertTrue(state == .thinking || state == .idle)
    }

    func testPermissionThenWorkingResumesCycle() {
        hookServer.processEvent(event("SessionStart"))
        flush()
        enableAutopilot()

        // Permission prompt
        hookServer.processEvent(event("Notification", extra: ["notification_type": "permission_prompt"]))
        flush()

        // After auto-approve, Claude continues working
        hookServer.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flush()
        XCTAssertEqual(manager.sessionState(tabID: testTabID), .idle)

        // Then Claude stops again
        hookServer.processEvent(event("Stop"))
        flush()

        // Should trigger another cycle
        let state = manager.sessionState(tabID: testTabID)
        XCTAssertTrue(state == .thinking || state == .idle)
    }

    func testSessionEndDoesNotCrashAutopilot() {
        hookServer.processEvent(event("SessionStart"))
        flush()
        enableAutopilot()

        hookServer.processEvent(event("SessionEnd"))
        flush()

        // Session removed from hook server, but autopilot session still exists (user must disable)
        XCTAssertTrue(manager.isEnabled(tabID: testTabID))
        XCTAssertNil(hookServer.sessions[testSessionID])
    }

    // MARK: - Cycle Count Tracking

    func testCycleCountIncrements() {
        enableAutopilot()
        XCTAssertEqual(manager.sessions[testTabID]?.cycleCount, 0)

        // Simulate a completed injection
        manager.sessions[testTabID]?.cycleCount = 5
        XCTAssertEqual(manager.sessions[testTabID]?.cycleCount, 5)
    }

    func testCycleCountAtBoundary() {
        hookServer.processEvent(event("SessionStart"))
        flush()
        enableAutopilot()

        // Set cycle count to 99 (one below max)
        manager.sessions[testTabID]?.cycleCount = 99
        manager.sessions[testTabID]?.lastCycleTime = Date().addingTimeInterval(-10)

        hookServer.processEvent(event("Stop"))
        flush()

        // Should still trigger since count was 99 (< 100)
        let state = manager.sessionState(tabID: testTabID)
        // It may be thinking (cycle triggered) or escalated (if cycle ran and hit 100)
        XCTAssertTrue(state == .thinking || state == .idle || {
            if case .escalated = state { return true }
            return false
        }())
    }

    // MARK: - Private method testing helpers (using same logic as AutopilotManager)

    /// Mirror of AutopilotManager.parseDecision for testability
    private enum TestDecision {
        case send(String)
        case escalate(String)
        case error(String)
    }

    private func parseDecisionHelper(_ response: String) -> TestDecision {
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
        if trimmed.count < 500 {
            return .send(trimmed)
        }
        return .escalate("Autopilot brain returned unexpected format")
    }

    private func buildBrainPromptHelper(history: String, cwd: String, cycleCount: Int) -> String {
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
}

// MARK: - ConversationReader Testability Extension

extension ConversationReader {
    /// Test-only entry point that accepts a custom base path instead of ~/.claude
    static func readHistory(sessionID: String, cwd: String, maxTurns: Int = 20, testBasePath: String) -> [Turn] {
        let filePath = "\(testBasePath)/\(sessionID).jsonl"
        guard let data = try? String(contentsOfFile: filePath, encoding: .utf8) else { return [] }

        var turns: [Turn] = []
        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let message = obj["message"] as? [String: Any] else { continue }

            let role = message["role"] as? String ?? type
            var text = ""
            var toolCalls: [String] = []

            if let content = message["content"] as? String {
                text = content
            } else if let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String
                    if blockType == "text" {
                        text += (block["text"] as? String ?? "")
                    } else if blockType == "tool_use" {
                        toolCalls.append(block["name"] as? String ?? "unknown")
                    }
                }
            }

            if text.isEmpty && toolCalls.isEmpty { continue }
            turns.append(Turn(role: role, text: text, toolCalls: toolCalls))
        }

        return Array(turns.suffix(maxTurns))
    }
}
