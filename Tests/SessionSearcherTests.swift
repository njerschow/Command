import XCTest
@testable import Command

/// Tests for SessionSearcher keyword scoring and ranking
final class SessionSearcherTests: XCTestCase {

    private var searcher: SessionSearcher!

    override func setUp() {
        super.setUp()
        searcher = SessionSearcher()
    }

    // MARK: - Test Helpers

    private func makeSession(
        summary: String,
        dir: String? = nil,
        tag: String? = nil,
        content: String? = nil,
        closedSecondsAgo: TimeInterval = 60
    ) -> SavedSession {
        SavedSession(
            tabID: "tab-\(UUID().uuidString.prefix(8))",
            title: summary,
            summary: summary,
            workingDirectory: dir,
            app: "Terminal",
            sessionTag: tag,
            content: content,
            closedAt: Date().addingTimeInterval(-closedSecondsAgo)
        )
    }

    // MARK: - Empty / No Match

    func testEmptyQueryReturnsNoResults() {
        let sessions = [makeSession(summary: "my project")]
        searcher.keywordSearch(query: "", sessions: sessions)
        XCTAssertTrue(searcher.keywordResults.isEmpty)
    }

    func testNoMatchReturnsEmpty() {
        let sessions = [makeSession(summary: "building API server")]
        searcher.keywordSearch(query: "zzzznotfound", sessions: sessions)
        XCTAssertTrue(searcher.keywordResults.isEmpty)
    }

    // MARK: - Title Matching

    func testExactTitleMatch() {
        let sessions = [
            makeSession(summary: "api server"),
            makeSession(summary: "api client"),
        ]
        searcher.keywordSearch(query: "api server", sessions: sessions)
        // Only "api server" matches "api server" — "api client" doesn't contain it
        XCTAssertEqual(searcher.keywordResults.count, 1)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "api server")
    }

    func testPrefixTitleMatch() {
        let sessions = [
            makeSession(summary: "deploy script runner"),
            makeSession(summary: "debugging logs"),
        ]
        searcher.keywordSearch(query: "deploy", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "deploy script runner")
    }

    func testSubstringTitleMatch() {
        let sessions = [makeSession(summary: "my-api-server")]
        searcher.keywordSearch(query: "api", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 1)
    }

    func testWordBoundaryTitleRankedAboveSubstring() {
        // "server" at word boundary in "api-server" should score higher than substring match in "observer"
        let sessions = [
            makeSession(summary: "observer pattern"),
            makeSession(summary: "api-server"),
        ]
        searcher.keywordSearch(query: "server", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 2)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "api-server")
    }

    // MARK: - Tag Matching

    func testExactTagMatch() {
        let sessions = [
            makeSession(summary: "my project", tag: "python"),
            makeSession(summary: "other project", tag: "node"),
        ]
        searcher.keywordSearch(query: "python", sessions: sessions)
        // Python tag session should rank first
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "my project")
    }

    // MARK: - Directory Matching

    func testDirectoryMatch() {
        let sessions = [
            makeSession(summary: "frontend", dir: "/Users/n/projects/webapp"),
            makeSession(summary: "backend", dir: "/Users/n/projects/api"),
        ]
        searcher.keywordSearch(query: "webapp", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 1)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "frontend")
    }

    // MARK: - Content Matching

    func testContentSubstringMatch() {
        let sessions = [
            makeSession(summary: "build log", content: "error: undefined variable foo_bar\ncompilation failed"),
            makeSession(summary: "clean build", content: "build succeeded\n0 errors"),
        ]
        searcher.keywordSearch(query: "foo_bar", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 1)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "build log")
    }

    func testContentWordBoundaryRankedAboveSubstring() {
        let sessions = [
            makeSession(summary: "session A", content: "running test_migration script"),
            makeSession(summary: "session B", content: "testing the remigration tool"),
        ]
        searcher.keywordSearch(query: "migration", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 2)
        // Word boundary match ("test_migration") should rank above substring ("remigration")
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "session A")
    }

    // MARK: - Ranking Priority

    func testTitleMatchRankedAboveContentMatch() {
        let sessions = [
            makeSession(summary: "unrelated title", content: "deploying to production"),
            makeSession(summary: "deploy pipeline", content: "some other content"),
        ]
        searcher.keywordSearch(query: "deploy", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 2)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "deploy pipeline")
    }

    func testRecencyBreaksTies() {
        // Two sessions with identical titles — more recent should rank first
        let sessions = [
            makeSession(summary: "ssh session", closedSecondsAgo: 3600),
            makeSession(summary: "ssh session", closedSecondsAgo: 60),
        ]
        searcher.keywordSearch(query: "ssh", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 2)
        // The more recent one (60s ago) should be first
        let first = searcher.keywordResults.first!.session
        let second = searcher.keywordResults.last!.session
        XCTAssertTrue(first.closedAt > second.closedAt)
    }

    // MARK: - Case Insensitivity

    func testCaseInsensitive() {
        let sessions = [makeSession(summary: "Running Docker Compose")]
        searcher.keywordSearch(query: "docker", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 1)
    }

    func testCaseInsensitiveContent() {
        let sessions = [makeSession(summary: "build", content: "ERROR: Module not found")]
        searcher.keywordSearch(query: "error", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 1)
    }

    // MARK: - Multiple Signals Stack

    func testMultipleSignalsBoostScore() {
        // Session that matches in title AND content AND directory should score highest
        let sessions = [
            makeSession(summary: "redis cache", dir: "/projects/redis", content: "redis-server started on port 6379"),
            makeSession(summary: "other thing", content: "connected to redis"),
        ]
        searcher.keywordSearch(query: "redis", sessions: sessions)
        XCTAssertEqual(searcher.keywordResults.count, 2)
        XCTAssertEqual(searcher.keywordResults.first?.session.summary, "redis cache")
        XCTAssertTrue(searcher.keywordResults.first!.score > searcher.keywordResults.last!.score)
    }
}
