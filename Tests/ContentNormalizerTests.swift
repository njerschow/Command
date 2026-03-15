import XCTest
@testable import Command

/// Tests for ContentNormalizer and SummaryManager local heuristics
/// covering 20+ real terminal scenarios
final class ContentNormalizerTests: XCTestCase {

    // MARK: - ANSI Stripping

    func testStripANSIColors() {
        let input = "\u{001B}[32m✓\u{001B}[0m All tests passed"
        let result = ContentNormalizer.normalize(input)
        XCTAssertEqual(result, "✓ All tests passed")
    }

    func testStripANSICursorMovement() {
        let input = "\u{001B}[2K\u{001B}[1GBuilding..."
        let result = ContentNormalizer.normalize(input)
        XCTAssertEqual(result, "Building...")
    }

    // MARK: - Braille Spinner Stripping

    func testStripBrailleSpinners() {
        // Claude Code uses these: ⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏
        let input = "⠙ Working on something..."
        let result = ContentNormalizer.normalize(input)
        XCTAssertEqual(result, "Working on something...")
    }

    func testStripOpenClawBraille() {
        let input = "⣾ Loading packages..."
        let result = ContentNormalizer.normalize(input)
        XCTAssertEqual(result, "Loading packages...")
    }

    // MARK: - Progress Bar Stripping

    func testStripProgressBar() {
        let input = "Downloading [=====>      ] 45%"
        let result = ContentNormalizer.normalize(input)
        XCTAssertTrue(!result.contains("[=====>"))
        XCTAssertTrue(!result.contains("45%"))
    }

    func testStripTimingInfo() {
        let input = "Build complete (12.3s)"
        let result = ContentNormalizer.normalize(input)
        XCTAssertTrue(!result.contains("12.3s"))
    }

    func testStripTimestamp() {
        let input = "Elapsed 00:01:23"
        let result = ContentNormalizer.normalize(input)
        XCTAssertTrue(!result.contains("00:01:23"))
    }

    // MARK: - Fingerprint Stability

    func testFingerprintStableAcrossSpinnerChanges() {
        let content1 = "⠋ Building project...\nCompiling file.swift"
        let content2 = "⠹ Building project...\nCompiling file.swift"
        XCTAssertEqual(
            ContentNormalizer.fingerprint(content1),
            ContentNormalizer.fingerprint(content2),
            "Fingerprint should be stable across spinner character changes"
        )
    }

    func testFingerprintChangesOnRealContentChange() {
        let content1 = "Compiling file1.swift\nBuild succeeded"
        let content2 = "Compiling file2.swift\nBuild failed"
        XCTAssertNotEqual(
            ContentNormalizer.fingerprint(content1),
            ContentNormalizer.fingerprint(content2)
        )
    }

    func testFingerprintStableAcrossProgressUpdates() {
        let content1 = "Installing packages [==>   ] 30%"
        let content2 = "Installing packages [=====>] 85%"
        XCTAssertEqual(
            ContentNormalizer.fingerprint(content1),
            ContentNormalizer.fingerprint(content2),
            "Progress bar changes shouldn't alter fingerprint"
        )
    }

    // MARK: - Last Lines Extraction

    func testLastLines() {
        let content = (1...20).map { "Line \($0)" }.joined(separator: "\n")
        let last5 = ContentNormalizer.lastLines(content, count: 5)
        XCTAssertTrue(last5.hasPrefix("Line 16"))
        XCTAssertTrue(last5.hasSuffix("Line 20"))
    }

    // MARK: - 20+ Terminal Scenarios

    // Scenario 1: Idle shell
    func testScenarioIdleShell() {
        let content = "Last login: Mon Mar 15 10:00:00 on ttys001\nn@mac ~ %"
        let fp = ContentNormalizer.fingerprint(content)
        XCTAssertFalse(fp.isEmpty)
    }

    // Scenario 2: Claude Code actively working
    func testScenarioClaudeCodeWorking() {
        let content = """
        ⏺ Let me analyze the code...

        ⏺ Read(Sources/App/AppDelegate.swift)
          ⎿ import AppKit...

        ⠙ Thinking...
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Thinking"))
        XCTAssertFalse(normalized.contains("⠙"))
    }

    // Scenario 3: Claude Code waiting for user
    func testScenarioClaudeCodeWaiting() {
        let content = """
        ⏺ I've made the changes. Would you like me to commit?

        ❯
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("❯"))
    }

    // Scenario 4: SSH session
    func testScenarioSSH() {
        let content = """
        root@server:~# systemctl status nginx
        ● nginx.service - A high performance web server
             Active: active (running) since Mon 2024-03-15
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("nginx"))
    }

    // Scenario 5: Long-running build (Swift)
    func testScenarioSwiftBuild() {
        let content = """
        Building for debugging...
        [45/120] Compiling MyApp ViewController.swift
        [46/120] Compiling MyApp NetworkManager.swift
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Compiling"))
    }

    // Scenario 6: npm dev server
    func testScenarioNpmDevServer() {
        let content = """
        > next dev

        ready - started server on 0.0.0.0:3000, url: http://localhost:3000
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("localhost:3000"))
    }

    // Scenario 7: Docker compose
    func testScenarioDockerCompose() {
        let content = """
        [+] Running 3/3
         ✔ Container db         Running
         ✔ Container redis      Running
         ✔ Container api        Running
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Container"))
    }

    // Scenario 8: Git operations
    func testScenarioGitOperation() {
        let content = """
        On branch main
        Your branch is up to date with 'origin/main'.

        Changes not staged for commit:
          modified:   Sources/App/AppDelegate.swift
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("branch main"))
    }

    // Scenario 9: Python REPL
    func testScenarioPythonREPL() {
        let content = """
        Python 3.12.0 (main, Oct  2 2023)
        >>> import pandas as pd
        >>> df = pd.read_csv('data.csv')
        >>> df.head()
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("pandas"))
    }

    // Scenario 10: vim/neovim
    func testScenarioVim() {
        let content = """
        import Foundation

        class AppDelegate {
            func setup() {
        ~
        ~
        -- INSERT --
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("INSERT"))
    }

    // Scenario 11: tail -f log watching
    func testScenarioTailLog() {
        let content = """
        2024-03-15 10:00:01 INFO  Request GET /api/users 200 12ms
        2024-03-15 10:00:02 INFO  Request POST /api/login 200 45ms
        2024-03-15 10:00:03 WARN  Rate limit approaching for IP 1.2.3.4
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Rate limit"))
    }

    // Scenario 12: Interactive prompt [y/N]
    func testScenarioInteractivePrompt() {
        let content = """
        The following packages will be removed:
          libfoo-dev libbar-dev
        Do you want to continue? [y/N]
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("[y/N]"))
    }

    // Scenario 13: Password prompt
    func testScenarioPasswordPrompt() {
        let content = """
        Connecting to server.example.com...
        Password:
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Password"))
    }

    // Scenario 14: htop / system monitor
    func testScenarioHtop() {
        let content = """
        CPU[||||||||   30.2%]   Mem[|||||||||||  2.1G/16.0G]
          PID USER      PRI  NI  VIRT   RES   SHR S CPU% MEM%
        12345 root       20   0  1.2G  256M  128M S  5.2  1.6
        """
        let normalized = ContentNormalizer.normalize(content)
        // Progress-like patterns may be stripped, but core data should remain
        XCTAssertTrue(normalized.contains("PID"))
    }

    // Scenario 15: Rust/Cargo build
    func testScenarioCargoBuilding() {
        let content = """
           Compiling serde v1.0.195
           Compiling tokio v1.35.1
           Compiling my-project v0.1.0
            Finished `dev` profile [unoptimized + debuginfo] target(s) in 12.34s
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Compiling"))
    }

    // Scenario 16: Go test running
    func testScenarioGoTest() {
        let content = """
        === RUN   TestUserCreate
        --- PASS: TestUserCreate (0.05s)
        === RUN   TestUserDelete
        --- FAIL: TestUserDelete (0.02s)
            user_test.go:45: expected nil error, got: not found
        FAIL
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("FAIL"))
    }

    // Scenario 17: npm install
    func testScenarioNpmInstall() {
        let content = """
        added 1245 packages, and audited 1246 packages in 32s

        145 packages are looking for funding
          run `npm fund` for details

        found 0 vulnerabilities
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("packages"))
    }

    // Scenario 18: Kubernetes/kubectl
    func testScenarioKubectl() {
        let content = """
        NAME                     READY   STATUS    RESTARTS   AGE
        api-7f9d8b4c5-x2j4k     1/1     Running   0          2d
        worker-5c8f9d7b6-m3n2p   1/1     Running   0          2d
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Running"))
    }

    // Scenario 19: OpenClaw TUI
    func testScenarioOpenClaw() {
        let content = """
        ┌──────────────────────────────────┐
        │  OpenClaw Package Manager  v1.2  │
        ├──────────────────────────────────┤
        │  ⣾ Resolving dependencies...     │
        └──────────────────────────────────┘
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertFalse(normalized.contains("⣾"))
        XCTAssertTrue(normalized.contains("Resolving dependencies"))
    }

    // Scenario 20: Restored/empty terminal
    func testScenarioRestoredTerminal() {
        let content = """
        Restored session: Thu Mar 14 09:00:00 PST 2024
        Last login: Thu Mar 14 09:00:00 on ttys001

        n@mac ~ %
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Restored session"))
    }

    // Scenario 21: make / Makefile build
    func testScenarioMakeBuild() {
        let content = """
        cc -o build/main main.c utils.c -Wall -O2
        ld: warning: directory not found for option '-L/usr/local/lib'
        make: *** [all] Error 1
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Error 1"))
    }

    // Scenario 22: mysql client
    func testScenarioMysql() {
        let content = """
        mysql> SELECT COUNT(*) FROM users;
        +----------+
        | COUNT(*) |
        +----------+
        |     1234 |
        +----------+
        mysql>
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("mysql>"))
    }

    // Scenario 23: Downloading with curl/wget
    func testScenarioDownload() {
        let content = """
        --2024-03-15 10:00:00--  https://example.com/file.tar.gz
        Resolving example.com... 1.2.3.4
        Connecting to example.com|1.2.3.4|:443... connected.
        HTTP request sent, awaiting response... 200 OK
        Saving to: 'file.tar.gz'
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("Saving to"))
    }

    // Scenario 24: Jest tests
    func testScenarioJestTests() {
        let content = """
         PASS  src/__tests__/api.test.ts
         FAIL  src/__tests__/auth.test.ts
          ● Auth > should validate token

            expect(received).toBe(expected)

        Tests:  1 failed, 1 passed, 2 total
        """
        let normalized = ContentNormalizer.normalize(content)
        XCTAssertTrue(normalized.contains("1 failed"))
    }
}
