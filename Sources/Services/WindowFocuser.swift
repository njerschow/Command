import AppKit
import Foundation

/// Focuses terminal windows and selects specific tabs
final class WindowFocuser {

    static let shared = WindowFocuser()

    func focus(group: TerminalGroup, tab: TerminalTab) {
        switch group.app {
        case .terminal:
            focusTerminalApp(windowID: group.windowID, tabIndex: tab.tabIndex)
        case .iterm:
            focusITerm(windowID: group.windowID, tabIndex: tab.tabIndex)
        default:
            focusGenericApp(bundleIdentifier: group.app.bundleIdentifier)
        }
    }

    func close(group: TerminalGroup, tab: TerminalTab) {
        switch group.app {
        case .terminal:
            closeTerminalTab(windowID: group.windowID, tabIndex: tab.tabIndex, totalTabs: group.tabs.count)
        case .iterm:
            closeITermTab(windowID: group.windowID, tabIndex: tab.tabIndex, totalTabs: group.tabs.count)
        default:
            break
        }
    }

    // MARK: - Terminal.app

    private func focusTerminalApp(windowID: Int, tabIndex: Int) {
        // Select the correct tab and bring window to front
        let script = """
        tell application "Terminal"
            activate
            repeat with w in windows
                if id of w is \(windowID) then
                    set index of w to 1
                    set selected tab of w to tab \(tabIndex + 1) of w
                    return true
                end if
            end repeat
            return false
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)

        if let error = error {
            print("[WindowFocuser] Error: \(error)")
        }
    }

    // MARK: - iTerm2

    private func focusITerm(windowID: Int, tabIndex: Int) {
        let script = """
        tell application "iTerm2"
            activate
            repeat with w in windows
                if id of w is \(windowID) then
                    select w
                    set current tab of w to item \(tabIndex + 1) of tabs of w
                    return true
                end if
            end repeat
            return false
        end tell
        """

        let appleScript = NSAppleScript(source: script)
        var error: NSDictionary?
        appleScript?.executeAndReturnError(&error)
        if let error { print("[WindowFocuser] iTerm2 error: \(error)") }
    }

    // MARK: - Generic

    private func focusGenericApp(bundleIdentifier: String) {
        guard let app = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleIdentifier
        ).first else { return }

        app.activate()
    }

    // MARK: - Close Tab

    private func closeTerminalTab(windowID: Int, tabIndex: Int, totalTabs: Int) {
        if totalTabs <= 1 {
            // Single tab — close the whole window
            let script = """
            tell application "Terminal"
                repeat with w in windows
                    if id of w is \(windowID) then
                        close w
                        return true
                    end if
                end repeat
                return false
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async {
                self.runAppleScript(script, label: "Terminal close window")
            }
        } else {
            // Multi-tab — send "exit" to the specific tab's shell
            let script = """
            tell application "Terminal"
                repeat with w in windows
                    if id of w is \(windowID) then
                        do script "exit" in tab \(tabIndex + 1) of w
                        return true
                    end if
                end repeat
                return false
            end tell
            """
            DispatchQueue.global(qos: .userInitiated).async {
                self.runAppleScript(script, label: "Terminal close tab")
            }
        }
    }

    private func closeITermTab(windowID: Int, tabIndex: Int, totalTabs: Int) {
        let script: String
        if totalTabs <= 1 {
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    if id of w is \(windowID) then
                        close w
                        return true
                    end if
                end repeat
                return false
            end tell
            """
        } else {
            script = """
            tell application "iTerm2"
                repeat with w in windows
                    if id of w is \(windowID) then
                        set t to item \(tabIndex + 1) of tabs of w
                        close t
                        return true
                    end if
                end repeat
                return false
            end tell
            """
        }
        runAppleScript(script, label: "iTerm2 close")
    }

    private func runAppleScript(_ source: String, label: String) {
        let appleScript = NSAppleScript(source: source)
        var error: NSDictionary?
        let result = appleScript?.executeAndReturnError(&error)
        if let error {
            Log.error("\(label) error: \(error)", category: "focus")
        } else {
            Log.info("\(label) success: \(result?.stringValue ?? "ok")", category: "focus")
        }
    }
}
