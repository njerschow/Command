import Foundation
import AppKit

/// Reads terminal content via AppleScript `history of tab`
final class ContentReader {

    /// Read the last N lines of terminal history
    func readHistory(windowID: Int, tabIndex: Int, lineCount: Int = 100) -> String? {
        let asTabIndex = tabIndex + 1  // AppleScript is 1-based
        let script = """
        tell application "Terminal"
            return history of tab \(asTabIndex) of window id \(windowID)
        end tell
        """
        guard let history = runAppleScript(script) else { return nil }
        let lines = history.components(separatedBy: "\n")
        return Array(lines.suffix(lineCount)).joined(separator: "\n")
    }

    private func runAppleScript(_ source: String) -> String? {
        let script = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        if error != nil { return nil }
        return result?.stringValue
    }
}
