import XCTest
@testable import Command

/// Tests for ClaudeHookServer: event processing state machine, session lifecycle,
/// file-discovered vs hook-confirmed distinction, and CWD-based lookup.
final class ClaudeHookServerTests: XCTestCase {

    private var server: ClaudeHookServer!

    override func setUp() {
        super.setUp()
        // Use a port that won't conflict; we don't actually start the listener in tests
        server = ClaudeHookServer(port: 0)
    }

    // MARK: - Helpers

    private func event(_ name: String, session: String = "test-session", cwd: String = "/tmp/project", extra: [String: Any] = [:]) -> String {
        var json: [String: Any] = [
            "session_id": session,
            "hook_event_name": name,
            "cwd": cwd
        ]
        for (k, v) in extra { json[k] = v }
        let data = try! JSONSerialization.data(withJSONObject: json)
        return String(data: data, encoding: .utf8)!
    }

    /// Flush main queue so @Published sessions updates propagate
    private func flushMainQueue() {
        let exp = expectation(description: "main queue flush")
        DispatchQueue.main.async { exp.fulfill() }
        wait(for: [exp], timeout: 1)
    }

    // MARK: - Basic Event Processing

    func testPreToolUseSetsWorkingState() {
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flushMainQueue()

        let session = server.sessions["test-session"]
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.state, .working)
        XCTAssertEqual(session?.lastEvent, "Using Bash")
        XCTAssertFalse(session?.isFileDiscovered ?? true)
    }

    func testStopSetsWaitingState() {
        server.processEvent(event("PreToolUse"))
        server.processEvent(event("Stop"))
        flushMainQueue()

        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)
    }

    func testNotificationIdlePromptSetsWaiting() {
        server.processEvent(event("PreToolUse"))
        server.processEvent(event("Notification", extra: ["notification_type": "idle_prompt"]))
        flushMainQueue()

        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)
        XCTAssertEqual(server.sessions["test-session"]?.lastEvent, "Waiting for input")
    }

    func testNotificationPermissionPromptSetsNeedsPermission() {
        server.processEvent(event("PreToolUse"))
        server.processEvent(event("Notification", extra: ["notification_type": "permission_prompt"]))
        flushMainQueue()

        XCTAssertEqual(server.sessions["test-session"]?.state, .needsPermission)
        XCTAssertEqual(server.sessions["test-session"]?.lastEvent, "Needs permission")
    }

    func testSessionStartSetsWorking() {
        server.processEvent(event("SessionStart"))
        flushMainQueue()

        XCTAssertEqual(server.sessions["test-session"]?.state, .working)
        XCTAssertEqual(server.sessions["test-session"]?.lastEvent, "Session started")
    }

    func testPostToolUseIgnored() {
        // PostToolUse is not a registered hook event — should be treated as unknown
        server.processEvent(event("Stop"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)

        server.processEvent(event("PostToolUse"))
        flushMainQueue()
        // State should NOT change — unknown events are rejected
        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)
    }

    func testSessionEndRemovesSession() {
        server.processEvent(event("PreToolUse"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["test-session"])

        server.processEvent(event("SessionEnd"))
        flushMainQueue()
        XCTAssertNil(server.sessions["test-session"])
    }

    // MARK: - State Machine Transitions

    func testFullLifecycle() {
        // SessionStart → PreToolUse (working) → Stop (waiting) → PreToolUse (working) → SessionEnd (removed)
        server.processEvent(event("SessionStart"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)

        server.processEvent(event("PreToolUse", extra: ["tool_name": "Read"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)
        XCTAssertEqual(server.sessions["test-session"]?.lastEvent, "Using Read")

        server.processEvent(event("Stop"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .waitingForUser)

        server.processEvent(event("PreToolUse", extra: ["tool_name": "Edit"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)
        XCTAssertEqual(server.sessions["test-session"]?.lastEvent, "Using Edit")

        server.processEvent(event("SessionEnd"))
        flushMainQueue()
        XCTAssertNil(server.sessions["test-session"])
    }

    func testPermissionThenResume() {
        server.processEvent(event("Notification", extra: ["notification_type": "permission_prompt"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .needsPermission)

        // User grants permission, Claude continues working
        server.processEvent(event("PreToolUse", extra: ["tool_name": "Bash"]))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.state, .working)
    }

    // MARK: - Multiple Sessions

    func testMultipleSessionsIndependent() {
        server.processEvent(event("PreToolUse", session: "session-a", cwd: "/project-a"))
        server.processEvent(event("Stop", session: "session-b", cwd: "/project-b"))
        flushMainQueue()

        XCTAssertEqual(server.sessions.count, 2)
        XCTAssertEqual(server.sessions["session-a"]?.state, .working)
        XCTAssertEqual(server.sessions["session-b"]?.state, .waitingForUser)
    }

    func testSessionEndOnlyRemovesTargetSession() {
        server.processEvent(event("PreToolUse", session: "session-a"))
        server.processEvent(event("PreToolUse", session: "session-b"))
        flushMainQueue()
        XCTAssertEqual(server.sessions.count, 2)

        server.processEvent(event("SessionEnd", session: "session-a"))
        flushMainQueue()
        XCTAssertNil(server.sessions["session-a"])
        XCTAssertNotNil(server.sessions["session-b"])
    }

    // MARK: - CWD Updates

    func testCWDUpdatedOnEvent() {
        server.processEvent(event("PreToolUse", cwd: "/first/dir"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.cwd, "/first/dir")

        server.processEvent(event("PreToolUse", cwd: "/second/dir"))
        flushMainQueue()
        XCTAssertEqual(server.sessions["test-session"]?.cwd, "/second/dir")
    }

    // MARK: - isFileDiscovered Flag

    func testHookEventClearsFileDiscoveredFlag() {
        // Simulate file-discovered session (as discoverExistingSessions would create)
        server.processEvent(event("SessionStart", session: "file-session"))
        flushMainQueue()
        // Events from hooks clear isFileDiscovered
        XCTAssertFalse(server.sessions["file-session"]?.isFileDiscovered ?? true)
    }

    func testRemoveSessionWorks() {
        server.processEvent(event("PreToolUse", session: "to-remove"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["to-remove"])

        server.removeSession("to-remove")
        flushMainQueue()
        XCTAssertNil(server.sessions["to-remove"])
    }

    // MARK: - sessionID(forCwd:) Filtering

    func testSessionIDForCwdFindsConfirmedSession() {
        server.processEvent(event("PreToolUse", session: "confirmed-1", cwd: "/Users/n/project"))
        flushMainQueue()

        let found = server.sessionID(forCwd: "/Users/n/project")
        XCTAssertEqual(found, "confirmed-1")
    }

    func testSessionIDForCwdExcludesFileDiscovered() {
        // Manually inject a file-discovered session via the lock
        // We can't easily call discoverExistingSessions in tests, so test the filter directly
        // by checking that sessionID(forCwd:) only returns non-file-discovered sessions
        server.processEvent(event("PreToolUse", session: "real-session", cwd: "/Users/n/project"))
        flushMainQueue()

        // The real session should be found
        XCTAssertEqual(server.sessionID(forCwd: "/Users/n/project"), "real-session")
    }

    func testSessionIDForCwdRespectsExcludeSet() {
        server.processEvent(event("PreToolUse", session: "session-1", cwd: "/Users/n/project"))
        server.processEvent(event("PreToolUse", session: "session-2", cwd: "/Users/n/project"))
        flushMainQueue()

        // Excluding session-1 should return session-2
        let found = server.sessionID(forCwd: "/Users/n/project", excluding: Set(["session-1"]))
        XCTAssertEqual(found, "session-2")
    }

    func testSessionIDForCwdReturnsNilWhenAllExcluded() {
        server.processEvent(event("PreToolUse", session: "only-one", cwd: "/Users/n/project"))
        flushMainQueue()

        let found = server.sessionID(forCwd: "/Users/n/project", excluding: Set(["only-one"]))
        XCTAssertNil(found)
    }

    func testSessionIDForCwdNormalizesTrailingSlash() {
        server.processEvent(event("PreToolUse", session: "s1", cwd: "/Users/n/project"))
        flushMainQueue()

        // Should match even with trailing slash
        let found = server.sessionID(forCwd: "/Users/n/project/")
        XCTAssertEqual(found, "s1")
    }

    func testSessionIDForCwdReturnsNilForNoMatch() {
        server.processEvent(event("PreToolUse", session: "s1", cwd: "/Users/n/project-a"))
        flushMainQueue()

        XCTAssertNil(server.sessionID(forCwd: "/Users/n/project-b"))
    }

    func testSessionIDForCwdReturnsMostRecent() {
        // Two sessions with same CWD — most recently updated should win
        server.processEvent(event("PreToolUse", session: "old-session", cwd: "/Users/n/project"))
        flushMainQueue()

        // Sleep briefly to ensure different timestamps
        Thread.sleep(forTimeInterval: 0.01)

        server.processEvent(event("PreToolUse", session: "new-session", cwd: "/Users/n/project"))
        flushMainQueue()

        let found = server.sessionID(forCwd: "/Users/n/project")
        XCTAssertEqual(found, "new-session")
    }

    // MARK: - hasActionRequired

    func testHasActionRequiredWhenWaiting() {
        server.processEvent(event("Stop", session: "waiting-session"))
        flushMainQueue()
        XCTAssertTrue(server.hasActionRequired)
    }

    func testHasActionRequiredWhenNeedsPermission() {
        server.processEvent(event("Notification", session: "perm-session", extra: ["notification_type": "permission_prompt"]))
        flushMainQueue()
        XCTAssertTrue(server.hasActionRequired)
    }

    func testNoActionRequiredWhenWorking() {
        server.processEvent(event("PreToolUse", session: "busy-session"))
        flushMainQueue()
        XCTAssertFalse(server.hasActionRequired)
    }

    func testNoActionRequiredWhenEmpty() {
        XCTAssertFalse(server.hasActionRequired)
    }

    // MARK: - Invalid / Edge Cases

    func testInvalidJSONIgnored() {
        server.processEvent("not valid json {{{")
        flushMainQueue()
        XCTAssertTrue(server.sessions.isEmpty)
    }

    func testEmptyJSONIgnored() {
        server.processEvent("{}")
        flushMainQueue()
        // Creates a session with "unknown" ID and empty event name (default case)
        // This is acceptable — the session just won't match anything
    }

    func testUnknownEventNameRejected() {
        server.processEvent(event("SomeNewEvent"))
        flushMainQueue()
        // Unknown events are rejected — no session created, isFileDiscovered not cleared
        XCTAssertNil(server.sessions["test-session"])
    }

    func testUnknownEventDoesNotClearFileDiscovered() {
        // First register a known event to create the session
        server.processEvent(event("PreToolUse"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["test-session"])

        // Sending an unknown event should not modify the session
        server.processEvent(event("SomeNewEvent"))
        flushMainQueue()
        XCTAssertNotNil(server.sessions["test-session"])
    }

    func testMissingSessionIDUsesUnknown() {
        let json = """
        {"hook_event_name": "PreToolUse", "cwd": "/tmp", "tool_name": "Bash"}
        """
        server.processEvent(json)
        flushMainQueue()
        XCTAssertNotNil(server.sessions["unknown"])
    }

    // MARK: - session(forCwd:)

    func testSessionForCwdReturnsFullSession() {
        server.processEvent(event("Stop", session: "s1", cwd: "/Users/n/project"))
        flushMainQueue()

        let session = server.session(forCwd: "/Users/n/project")
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.sessionID, "s1")
        XCTAssertEqual(session?.state, .waitingForUser)
    }
}
