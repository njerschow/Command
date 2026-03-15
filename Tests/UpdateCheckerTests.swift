import XCTest
@testable import Command

final class UpdateCheckerTests: XCTestCase {
    // MARK: - Version Comparison

    func testNewerMajorVersion() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "2.0.0", local: "1.0.0"))
    }

    func testNewerMinorVersion() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "1.1.0", local: "1.0.0"))
    }

    func testNewerPatchVersion() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "1.0.1", local: "1.0.0"))
    }

    func testSameVersionNotNewer() {
        XCTAssertFalse(UpdateChecker.compareVersions(remote: "1.0.0", local: "1.0.0"))
    }

    func testOlderVersionNotNewer() {
        XCTAssertFalse(UpdateChecker.compareVersions(remote: "1.0.0", local: "2.0.0"))
    }

    func testDifferentLengthVersions() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "1.0.1", local: "1.0"))
        XCTAssertFalse(UpdateChecker.compareVersions(remote: "1.0", local: "1.0.1"))
    }

    func testMajorBumpIgnoresMinor() {
        XCTAssertTrue(UpdateChecker.compareVersions(remote: "2.0.0", local: "1.9.9"))
    }

    // MARK: - Video URL Extraction

    func testExtractVideoFromHTMLTag() {
        let md = """
        ## What's New
        <video src="https://example.com/demo.mp4"></video>
        Some notes here.
        """
        XCTAssertEqual(
            UpdateChecker.extractVideoURL(from: md),
            "https://example.com/demo.mp4"
        )
    }

    func testExtractVideoFromRawURL() {
        let md = """
        ## What's New
        - Feature A
        https://example.com/release.mp4
        - Feature B
        """
        XCTAssertEqual(
            UpdateChecker.extractVideoURL(from: md),
            "https://example.com/release.mp4"
        )
    }

    func testExtractVideoFromMarkdownImage() {
        let md = """
        ![demo](https://example.com/preview.mov)
        """
        XCTAssertEqual(
            UpdateChecker.extractVideoURL(from: md),
            "https://example.com/preview.mov"
        )
    }

    func testNoVideoReturnsNil() {
        let md = """
        ## What's New
        - Bug fixes
        - Performance improvements
        """
        XCTAssertNil(UpdateChecker.extractVideoURL(from: md))
    }

    func testVideoTagWithAttributes() {
        let md = """
        <video autoplay muted src="https://cdn.example.com/v1.mp4" width="600"></video>
        """
        XCTAssertEqual(
            UpdateChecker.extractVideoURL(from: md),
            "https://cdn.example.com/v1.mp4"
        )
    }

    // MARK: - Strip Video Markdown

    func testStripVideoTag() {
        let md = """
        ## Changes
        <video src="https://example.com/demo.mp4"></video>
        - Fix A
        """
        let stripped = UpdatePopoverView.stripVideoMarkdown(md)
        XCTAssertFalse(stripped.contains("video"))
        XCTAssertTrue(stripped.contains("Fix A"))
    }

    func testStripRawVideoURL() {
        let md = """
        ## Changes
        https://example.com/demo.mp4
        - Fix B
        """
        let stripped = UpdatePopoverView.stripVideoMarkdown(md)
        XCTAssertFalse(stripped.contains(".mp4"))
        XCTAssertTrue(stripped.contains("Fix B"))
    }

    func testStripVideoMarkdownImage() {
        let md = """
        ![demo](https://example.com/preview.mov)
        Some text
        """
        let stripped = UpdatePopoverView.stripVideoMarkdown(md)
        XCTAssertFalse(stripped.contains(".mov"))
        XCTAssertTrue(stripped.contains("Some text"))
    }
}
