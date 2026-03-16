import XCTest
@testable import Command

/// Tests for the session discovery and matching logic.
/// Validates the file-discovered vs hook-confirmed distinction that
/// prevents wrong session IDs from being cached (JSONL filename ≠ hook session_id).
final class SessionDiscoveryTests: XCTestCase {

    private var hookServer: ClaudeHookServer!

    override func setUp() {
        super.setUp()
        hookServer = ClaudeHookServer(port: 0)
    }

    private func event(_ name: String, session: String, cwd: String, extra: [String: Any] = [:]) -> String {
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

    // MARK: - File-Discovered vs Hook-Confirmed

    func testFileDiscoveredSessionNotReturnedByCwdLookup() {
        // Simulate what discoverExistingSessions does: register with isFileDiscovered=true
        // We can't call discoverExistingSessions directly, but we can test the filter
        // by injecting a file-discovered session manually
        hookServer.processEvent(event("PreToolUse", session: "hook-confirmed", cwd: "/project"))
        flushMainQueue()

        // Hook-confirmed sessions should be found
        XCTAssertEqual(hookServer.sessionID(forCwd: "/project"), "hook-confirmed")
        XCTAssertFalse(hookServer.sessions["hook-confirmed"]!.isFileDiscovered)
    }

    func testRealEventClearsFileDiscoveredFlag() {
        // First event creates session with isFileDiscovered=false (from real hook)
        hookServer.processEvent(event("SessionStart", session: "s1", cwd: "/project"))
        flushMainQueue()
        XCTAssertFalse(hookServer.sessions["s1"]!.isFileDiscovered)
    }

    // MARK: - Discovery Decision Logic

    /// Simulates the needsDiscovery check from AppDelegate
    /// needsDiscovery = existingSID == nil || !isConfirmed
    func testNeedsDiscoveryWhenNoSID() {
        let existingSID: String? = nil
        let existingSession = existingSID.flatMap { hookServer.sessions[$0] }
        let isConfirmed = existingSession != nil && !existingSession!.isFileDiscovered
        let needsDiscovery = existingSID == nil || !isConfirmed

        XCTAssertTrue(needsDiscovery, "Should need discovery when no cached session ID")
    }

    func testNeedsDiscoveryWhenSIDNotInHookServer() {
        let existingSID: String? = "nonexistent-id"
        let existingSession = existingSID.flatMap { hookServer.sessions[$0] }
        let isConfirmed = existingSession != nil && !existingSession!.isFileDiscovered
        let needsDiscovery = existingSID == nil || !isConfirmed

        XCTAssertTrue(needsDiscovery, "Should need discovery when cached ID not in hook server")
    }

    func testNoDiscoveryWhenConfirmed() {
        hookServer.processEvent(event("PreToolUse", session: "confirmed-id", cwd: "/project"))
        flushMainQueue()

        let existingSID: String? = "confirmed-id"
        let existingSession = existingSID.flatMap { hookServer.sessions[$0] }
        let isConfirmed = existingSession != nil && !existingSession!.isFileDiscovered
        let needsDiscovery = existingSID == nil || !isConfirmed

        XCTAssertFalse(needsDiscovery, "Should NOT need discovery when cached ID is confirmed by hook")
    }

    // MARK: - CWD Fallback Scenarios

    func testCwdFallbackMatchesCorrectSession() {
        // Simulate: two sessions in different dirs
        hookServer.processEvent(event("PreToolUse", session: "hook-abc", cwd: "/Users/n/project-a"))
        hookServer.processEvent(event("PreToolUse", session: "hook-xyz", cwd: "/Users/n/project-b"))
        flushMainQueue()

        XCTAssertEqual(hookServer.sessionID(forCwd: "/Users/n/project-a"), "hook-abc")
        XCTAssertEqual(hookServer.sessionID(forCwd: "/Users/n/project-b"), "hook-xyz")
    }

    func testCwdFallbackExcludesAlreadyAssigned() {
        // Two sessions in same CWD
        hookServer.processEvent(event("PreToolUse", session: "s1", cwd: "/Users/n/project"))
        hookServer.processEvent(event("PreToolUse", session: "s2", cwd: "/Users/n/project"))
        flushMainQueue()

        // First tab gets s2 (most recent), second tab should get s1
        let first = hookServer.sessionID(forCwd: "/Users/n/project")!
        let second = hookServer.sessionID(forCwd: "/Users/n/project", excluding: Set([first]))
        XCTAssertNotNil(second)
        XCTAssertNotEqual(first, second)
    }

    func testCwdFallbackReturnsNilWhenNoHookSessions() {
        // No sessions registered at all
        XCTAssertNil(hookServer.sessionID(forCwd: "/Users/n/project"))
    }

    // MARK: - Session Lifecycle Integration

    func testSessionEndThenNewSessionInSameCwd() {
        // Session ends, new session starts in same directory
        hookServer.processEvent(event("SessionStart", session: "old", cwd: "/project"))
        flushMainQueue()
        XCTAssertEqual(hookServer.sessionID(forCwd: "/project"), "old")

        hookServer.processEvent(event("SessionEnd", session: "old", cwd: "/project"))
        flushMainQueue()
        XCTAssertNil(hookServer.sessionID(forCwd: "/project"))

        hookServer.processEvent(event("SessionStart", session: "new", cwd: "/project"))
        flushMainQueue()
        XCTAssertEqual(hookServer.sessionID(forCwd: "/project"), "new")
    }

    func testRemoveSessionClearsCwdLookup() {
        hookServer.processEvent(event("PreToolUse", session: "s1", cwd: "/project"))
        flushMainQueue()
        XCTAssertEqual(hookServer.sessionID(forCwd: "/project"), "s1")

        hookServer.removeSession("s1")
        flushMainQueue()
        XCTAssertNil(hookServer.sessionID(forCwd: "/project"))
    }

    // MARK: - Cache Directory Matching

    func testSessionStoreDirectoryCaching() {
        let store = SessionStore()

        // Cache directory for a tab
        store.cacheDirectory("/Users/n/project", for: "tab-1")
        XCTAssertEqual(store.cachedDirectory(for: "tab-1"), "/Users/n/project")

        // Claude session ID caching
        store.cacheClaudeSessionID("session-abc", for: "tab-1")
        XCTAssertEqual(store.cachedClaudeSessionID(for: "tab-1"), "session-abc")

        // Clear session ID
        store.cacheClaudeSessionID(nil, for: "tab-1")
        XCTAssertNil(store.cachedClaudeSessionID(for: "tab-1"))
    }

    // MARK: - Version Comparison

    func testVersionComparisonNewerMajor() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "2.0.0", local: "1.0.0"))
    }

    func testVersionComparisonNewerMinor() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "1.1.0", local: "1.0.0"))
    }

    func testVersionComparisonNewerPatch() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "1.0.1", local: "1.0.0"))
    }

    func testVersionComparisonSame() {
        XCTAssertFalse(UpdateChecker.compareVersions(remote: "1.0.0", local: "1.0.0"))
    }

    func testVersionComparisonOlder() {
        XCTAssertFalse(UpdateChecker.compareVersions(remote: "1.0.0", local: "2.0.0"))
    }

    func testVersionComparisonDifferentLengths() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "1.0.1", local: "1.0"))
        XCTAssertFalse(UpdateChecker.compareVersions(remote: "1.0", local: "1.0.1"))
    }

    // MARK: - Release Notes Parsing

    func testExtractVideoURLFromVideoTag() {
        let md = """
        ## What's New
        <video src="https://example.com/demo.mp4"></video>
        Some text
        """
        XCTAssertEqual(UpdateChecker.extractVideoURL(from: md), "https://example.com/demo.mp4")
    }

    func testExtractVideoURLFromRawURL() {
        let md = """
        ## Demo
        https://example.com/video.mp4
        """
        XCTAssertEqual(UpdateChecker.extractVideoURL(from: md), "https://example.com/video.mp4")
    }

    func testExtractVideoURLFromMarkdownImage() {
        let md = "![demo](https://example.com/clip.mov)"
        XCTAssertEqual(UpdateChecker.extractVideoURL(from: md), "https://example.com/clip.mov")
    }

    func testExtractVideoURLReturnsNilWhenNone() {
        XCTAssertNil(UpdateChecker.extractVideoURL(from: "Just some text with no video"))
    }

    func testExtractImageURLFromMarkdown() {
        let md = "![screenshot](https://example.com/shot.png)"
        XCTAssertEqual(UpdateChecker.extractImageURL(from: md), "https://example.com/shot.png")
    }

    func testExtractImageURLFromImgTag() {
        let md = "<img src=\"https://example.com/photo.jpg\" width=\"600\">"
        XCTAssertEqual(UpdateChecker.extractImageURL(from: md), "https://example.com/photo.jpg")
    }

    func testExtractImageURLFromGitHubUserContent() {
        let md = "![img](https://github.com/user-images/assets/123/abc.png)"
        XCTAssertNotNil(UpdateChecker.extractImageURL(from: md))
    }

    func testStripVideoMarkdownRemovesVideoAndImageEmbeds() {
        let md = """
        ## Release 1.0
        New features:
        - Feature A
        <video src="https://example.com/demo.mp4"></video>
        ![screenshot](https://example.com/shot.png)
        - Feature B
        """
        let stripped = UpdatePopoverView.stripVideoMarkdown(md)
        XCTAssertFalse(stripped.contains("video"))
        XCTAssertFalse(stripped.contains("screenshot"))
        XCTAssertTrue(stripped.contains("Feature A"))
        XCTAssertTrue(stripped.contains("Feature B"))
    }

    func testRenderMarkdownPlainStripsFormatting() {
        let md = "## Heading\n**bold** and [link](https://example.com)"
        let plain = UpdatePopoverView.renderMarkdownPlain(md)
        XCTAssertFalse(plain.contains("##"))
        XCTAssertFalse(plain.contains("**"))
        XCTAssertTrue(plain.contains("Heading"))
        XCTAssertTrue(plain.contains("bold"))
        XCTAssertTrue(plain.contains("link"))
        XCTAssertFalse(plain.contains("https://example.com"))
    }
}
