import AppKit
import Darwin

// Prevent duplicate instances using a file lock (works reliably for dev builds too)
let lockPath = "/tmp/com.command.app.lock"
let lockFD = open(lockPath, O_CREAT | O_RDWR, 0o600)
if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
    // Another instance holds the lock — try to activate it and exit
    let runningApps = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "com.command.app")
    runningApps.first { $0 != .current }?.activate()
    exit(0)
}
// Lock held for the lifetime of the process (released automatically on exit)

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
