import AppKit

// Prevent duplicate instances
let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.command.app")
if runningApps.count > 1 {
    // Another instance is already running — activate it and exit
    runningApps.first { $0 != .current }?.activate()
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
