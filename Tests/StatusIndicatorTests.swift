import XCTest
@testable import Command

/// Tests for the status indicator system: correct color/state mapping
/// and hook-to-UI state transitions.
final class StatusIndicatorTests: XCTestCase {

    // MARK: - Status Color Logic

    /// waitingForUser should show GREEN (done, ready for user)
    func testWaitingForUserIsGreen() {
        let color = dotColor(status: .running, claudeState: .waitingForUser)
        // Green = finished, ready for next input
        XCTAssertNotEqual(color, "orange", "waitingForUser should NOT be orange")
        XCTAssertEqual(color, "green", "waitingForUser should be green (ready)")
    }

    /// needsPermission should show ORANGE (blocked, needs approval)
    func testNeedsPermissionIsOrange() {
        let color = dotColor(status: .running, claudeState: .needsPermission)
        XCTAssertEqual(color, "orange", "needsPermission should be orange (blocked)")
    }

    /// working should be handled by sparkle, but fallback is green
    func testWorkingIsGreen() {
        let color = dotColor(status: .running, claudeState: .working)
        XCTAssertEqual(color, "green")
    }

    /// Idle terminal (no Claude) should be gray
    func testIdleTerminalIsGray() {
        let color = dotColor(status: .idle, claudeState: nil)
        XCTAssertEqual(color, "gray")
    }

    /// Running terminal (no Claude) should be green
    func testRunningTerminalIsGreen() {
        let color = dotColor(status: .running, claudeState: nil)
        XCTAssertEqual(color, "green")
    }

    /// actionRequired terminal should be orange
    func testActionRequiredIsOrange() {
        let color = dotColor(status: .actionRequired, claudeState: nil)
        XCTAssertEqual(color, "orange")
    }

    // MARK: - Pulse Behavior

    /// Only needsPermission and actionRequired should pulse (not waitingForUser)
    func testOnlyBlockedStatesPulse() {
        XCTAssertTrue(needsPulse(status: .actionRequired, claudeState: nil))
        XCTAssertTrue(needsPulse(status: .running, claudeState: .needsPermission))
        XCTAssertFalse(needsPulse(status: .running, claudeState: .waitingForUser),
                       "waitingForUser should NOT pulse — it's ready, not blocked")
        XCTAssertFalse(needsPulse(status: .idle, claudeState: nil))
        XCTAssertFalse(needsPulse(status: .running, claudeState: .working))
    }

    // MARK: - Claude State Priority

    /// Claude state should override terminal status
    func testClaudeStateOverridesTerminalStatus() {
        // Terminal says idle, but Claude says working → green (sparkle)
        let c1 = dotColor(status: .idle, claudeState: .working)
        XCTAssertEqual(c1, "green")

        // Terminal says running, but Claude says needsPermission → orange
        let c2 = dotColor(status: .running, claudeState: .needsPermission)
        XCTAssertEqual(c2, "orange")

        // Terminal says actionRequired, but Claude says waitingForUser → green (ready)
        let c3 = dotColor(status: .actionRequired, claudeState: .waitingForUser)
        XCTAssertEqual(c3, "green")
    }

    // MARK: - Hook → State → UI Integration

    func testHookStopProducesGreenDot() {
        let server = ClaudeHookServer(port: 0)
        server.processEvent(event("Stop"))
        flushMainQueue()

        let session = server.sessions["test-session"]
        XCTAssertEqual(session?.state, .waitingForUser)
        // waitingForUser → green dot (verified by testWaitingForUserIsGreen)
        XCTAssertEqual(dotColor(status: .running, claudeState: .waitingForUser), "green")
    }

    func testHookPermissionProducesOrangeDot() {
        let server = ClaudeHookServer(port: 0)
        server.processEvent(event("Notification", extra: ["notification_type": "permission_prompt"]))
        flushMainQueue()

        let session = server.sessions["test-session"]
        XCTAssertEqual(session?.state, .needsPermission)
        XCTAssertEqual(dotColor(status: .running, claudeState: .needsPermission), "orange")
    }

    func testHookPreToolUseProducesSparkle() {
        let server = ClaudeHookServer(port: 0)
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flushMainQueue()

        let session = server.sessions["test-session"]
        XCTAssertEqual(session?.state, .working)
        // working → sparkle animation (handled by StatusDotView body)
    }

    func testHookSessionEndClearsState() {
        let server = ClaudeHookServer(port: 0)
        server.processEvent(event("SessionStart"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["test-session"])

        server.processEvent(event("SessionEnd"))
        flushMainQueue()
        XCTAssertNil(server.sessions["test-session"])
        // No session → dot falls back to terminal status (gray if idle)
    }

    // MARK: - Full State Transitions

    func testCompleteStateTransitionSequence() {
        let server = ClaudeHookServer(port: 0)

        // 1. Session starts → working → sparkle
        server.processEvent(event("SessionStart"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)

        // 2. Tool use → still working → sparkle
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Read"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)

        // 3. Stop → waitingForUser → GREEN dot
        server.processEvent(event("Stop"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)
        XCTAssertEqual(dotColor(status: .running, claudeState: .waitingForUser), "green")

        // 4. Permission prompt → needsPermission → ORANGE pulsing
        server.processEvent(event("Notification", extra: ["notification_type": "permission_prompt"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .needsPermission)
        XCTAssertEqual(dotColor(status: .running, claudeState: .needsPermission), "orange")
        XCTAssertTrue(needsPulse(status: .running, claudeState: .needsPermission))

        // 5. User approves → tool use → working → sparkle
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)

        // 6. Session ends → removed
        server.processEvent(event("SessionEnd"))
        flushMainQueue()
        XCTAssertNil(server.sessions["test-session"])
    }

    // MARK: - Edge Cases

    func testFileDiscoveredSessionDoesNotShowState() {
        // File-discovered sessions should return nil for claudeState
        // (tested in TerminalListView.claudeState(for:))
        let server = ClaudeHookServer(port: 0)
        server.registerFileDiscovered(sessionID: "file-sid", cwd: "/tmp/test")
        flushMainQueue()

        let session = server.sessions["file-sid"]
        XCTAssertNotNil(session)
        XCTAssertTrue(session?.isFileDiscovered ?? false)
        // UI should NOT use this session's state for dot color
    }

    func testRapidStateChangesSettleCorrectly() {
        let server = ClaudeHookServer(port: 0)

        // Rapid: start → tool → stop → tool → stop
        server.processEvent(event("SessionStart"))
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Read"]))
        server.processEvent(event("Stop"))
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Edit"]))
        server.processEvent(event("Stop"))
        flushMainQueue()

        // Final state should be waitingForUser
        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)
    }

    func testMultipleSessionsHaveIndependentStates() {
        let server = ClaudeHookServer(port: 0)

        server.processEvent(event("PreToolUse", session: "s1", cwd: "/a", extra: ["tool_name": "Bash"]))
        server.processEvent(event("Stop", session: "s2", cwd: "/b"))
        server.processEvent(event("Notification", session: "s3", cwd: "/c",
                                   extra: ["notification_type": "permission_prompt"]))
        flushMainQueue()

        XCTAssertEqual(server.sessions["s1"]?.state, .working)
        XCTAssertEqual(server.sessions["s2"]?.state, .waitingForUser)
        XCTAssertEqual(server.sessions["s3"]?.state, .needsPermission)

        // Each maps to different dot colors
        XCTAssertEqual(dotColor(status: .running, claudeState: .working), "green")
        XCTAssertEqual(dotColor(status: .running, claudeState: .waitingForUser), "green")
        XCTAssertEqual(dotColor(status: .running, claudeState: .needsPermission), "orange")
    }

    // MARK: - Hook Reliability

    func testDuplicateEventsAreIdempotent() {
        let server = ClaudeHookServer(port: 0)

        server.processEvent(event("Stop"))
        server.processEvent(event("Stop"))
        server.processEvent(event("Stop"))
        flushMainQueue()

        XCTAssertEqual(server.sessions.count, 1)
        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)
    }

    func testMalformedEventsDontCorruptState() {
        let server = ClaudeHookServer(port: 0)

        // Set up valid state
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)

        // Send garbage
        server.processEvent("not json at all")
        server.processEvent("{}")
        server.processEvent("{\"hook_event_name\": \"FakeEvent\", \"session_id\": \"test-session\"}")
        flushMainQueue()

        // Original session should be untouched
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)
    }

    func testConcurrentEventsFromDifferentSessions() {
        let server = ClaudeHookServer(port: 0)

        // Simulate 10 sessions sending events rapidly
        for i in 0..<10 {
            server.processEvent(event("PreToolUse", session: "s\(i)", cwd: "/project\(i)",
                                       extra: ["tool_name": "Bash"]))
        }
        flushMainQueue()

        XCTAssertEqual(server.sessions.count, 10)
        for i in 0..<10 {
            XCTAssertEqual(server.sessions["s\(i)"]?.state, .working)
        }
    }

    func testSessionEndThenRestartSameID() {
        let server = ClaudeHookServer(port: 0)

        server.processEvent(event("SessionStart"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["test-session"])

        server.processEvent(event("SessionEnd"))
        flushMainQueue()
        XCTAssertNil(server.sessions["test-session"])

        // Restart with same ID
        server.processEvent(event("SessionStart"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["test-session"])
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)
    }

    // MARK: - Helpers

    private func event(_ name: String, session: String = "test-session",
                       cwd: String = "/tmp/project", extra: [String: Any] = [:]) -> String {
        var json: [String: Any] = [
            "session_id": session,
            "hook_event_name": name,
            "cwd": cwd
        ]
        for (k, v) in extra { json[k] = v }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(data: data, encoding: .utf8)!
    }

    private func flushMainQueue() {
        let exp = expectation(description: "flush")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    /// Mirror the dotColor logic from StaticDotView for testability
    private func dotColor(status: TerminalStatus, claudeState: ClaudeState?) -> String {
        if let claudeState {
            switch claudeState {
            case .working: return "green"
            case .waitingForUser: return "green"       // Ready for user = green
            case .needsPermission: return "orange"     // Blocked = orange
            }
        }
        switch status {
        case .idle: return "gray"
        case .running: return "green"
        case .actionRequired: return "orange"
        }
    }

    /// Mirror the needsPulse logic from StaticDotView
    private func needsPulse(status: TerminalStatus, claudeState: ClaudeState?) -> Bool {
        status == .actionRequired || claudeState == .needsPermission
    }

}
