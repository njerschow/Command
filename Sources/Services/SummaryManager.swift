import Foundation
import Combine

/// Orchestrates terminal summaries: fingerprinting, local heuristics, AI generation, rolling context
final class SummaryManager: ObservableObject {
    @Published var contexts: [String: TerminalContext] = [:]

    private let contentReader = ContentReader()
    private var timer: Timer?
    private var isRefreshing = false
    private weak var appState: AppState?

    // MARK: - Lifecycle

    func start(appState: AppState) {
        self.appState = appState

        // First refresh after 3s (let scanner populate terminal list first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refresh()
        }

        // Then every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Called when popover opens — refresh if any tab is stale
    func refreshIfNeeded() {
        let staleThreshold: TimeInterval = 300
        let hasStale = contexts.values.contains {
            Date().timeIntervalSince($0.lastChecked) > staleThreshold
        }
        if hasStale || contexts.isEmpty {
            refresh()
        }
    }

    // MARK: - Core Refresh

    func refresh() {
        guard !isRefreshing, let groups = appState?.terminalGroups, !groups.isEmpty else { return }
        isRefreshing = true

        let snapshot = self.contexts

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            var updated = snapshot
            var aiBatch: [(id: String, wid: Int, tidx: Int, content: String, narrative: String)] = []
            var activeIDs = Set<String>()

            for group in groups {
                for tab in group.tabs {
                    activeIDs.insert(tab.id)
                    var ctx = updated[tab.id] ?? TerminalContext()

                    // 1. Idle tabs — no content read needed
                    if tab.status == .idle {
                        let prev = ctx.currentSummary
                        ctx.currentSummary = "Shell — idle"
                        ctx.summaryMethod = .idle
                        ctx.lastChecked = Date()
                        if prev != ctx.currentSummary && !prev.isEmpty {
                            ctx.pushHistory(prev)
                        }
                        updated[tab.id] = ctx
                        continue
                    }

                    // 2. Adaptive interval — skip if unchanged many times
                    if ctx.unchangedCount >= 5 && ctx.unchangedCount % 3 != 0 {
                        ctx.unchangedCount += 1
                        updated[tab.id] = ctx
                        continue
                    }

                    // 3. Read content
                    guard let content = self.contentReader.readHistory(
                        windowID: group.windowID,
                        tabIndex: tab.tabIndex
                    ) else {
                        updated[tab.id] = ctx
                        continue
                    }

                    let last10 = ContentNormalizer.lastLines(content, count: 10)
                    let fp = ContentNormalizer.fingerprint(last10)
                    ctx.lastChecked = Date()

                    // 4. Unchanged?
                    if fp == ctx.lastFingerprint && !ctx.currentSummary.isEmpty {
                        ctx.unchangedCount += 1
                        updated[tab.id] = ctx
                        continue
                    }

                    // 5. Content changed — also check for input prompts
                    ctx.unchangedCount = 0
                    ctx.lastFingerprint = fp
                    ctx.lastChanged = Date()
                    ctx.statusOverride = self.detectInputWaiting(content: content)

                    // 6. Try local heuristic
                    if let local = self.localHeuristic(tab: tab, content: content) {
                        let prev = ctx.currentSummary
                        ctx.currentSummary = local
                        ctx.summaryMethod = .localHeuristic
                        ctx.lastSummarized = Date()
                        if prev != local && !prev.isEmpty { ctx.pushHistory(prev) }
                        updated[tab.id] = ctx
                        continue
                    }

                    // 7. Queue for AI batch
                    aiBatch.append((
                        tab.id, group.windowID, tab.tabIndex,
                        ContentNormalizer.normalize(content),
                        ctx.narrativeContext
                    ))
                    updated[tab.id] = ctx
                }
            }

            // Prune orphaned contexts
            for key in updated.keys where !activeIDs.contains(key) {
                updated.removeValue(forKey: key)
            }

            // 8. Batch AI summaries
            if !aiBatch.isEmpty {
                let results = self.generateAISummaries(batch: aiBatch)
                for (id, summary) in results {
                    if var ctx = updated[id] {
                        let prev = ctx.currentSummary
                        ctx.currentSummary = summary
                        ctx.summaryMethod = .aiGenerated
                        ctx.lastSummarized = Date()
                        if prev != summary && !prev.isEmpty { ctx.pushHistory(prev) }
                        updated[id] = ctx
                    }
                }
            }

            DispatchQueue.main.async { [weak self] in
                self?.contexts = updated
                self?.isRefreshing = false
            }
        }
    }

    // MARK: - Local Heuristics

    private func localHeuristic(tab: TerminalTab, content: String) -> String? {
        let title = tab.title.lowercased()
        let lower = content.lowercased()

        // Claude Code — detect by braille spinners or "⏺" marker
        if lower.contains("claude") && (content.contains("⏺") || lower.contains("claudecode")) {
            return "Claude Code session"
        }

        // SSH
        if title.contains("ssh") || lower.range(of: "^ssh\\s+", options: .regularExpression) != nil {
            if let host = extractSSHHost(from: tab.title) {
                return "SSH — \(host)"
            }
            return "SSH session"
        }

        // Vim/Neovim
        if title.contains("vim") || title.contains("nvim") {
            return "Editing in vim"
        }

        // Server listening
        if lower.contains("listening on port") || lower.contains("server started") ||
           lower.contains("ready on http") {
            return "Server running"
        }

        // Docker
        if lower.contains("docker compose") || lower.contains("docker run") {
            return "Docker running"
        }

        // Building
        if lower.contains("compiling ") || lower.contains("building for") ||
           lower.contains("build complete") || lower.contains("build succeeded") {
            return "Building project"
        }

        // Log watching
        if title.contains("tail") || lower.contains("tail -f") {
            return "Watching logs"
        }

        // Python REPL
        if title.contains("python") || lower.contains(">>> ") {
            return "Python session"
        }

        // htop/top
        if title.contains("htop") || (title.contains("top") && lower.contains("cpu")) {
            return "System monitor"
        }

        // npm/yarn
        if lower.contains("npm run ") || lower.contains("yarn ") {
            return "npm script running"
        }

        return nil  // Needs AI
    }

    private func extractSSHHost(from title: String) -> String? {
        let pattern = "(?:ssh\\s+(?:\\w+@)?)([\\w.-]+)"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: title, range: NSRange(title.startIndex..., in: title)),
              let range = Range(match.range(at: 1), in: title) else { return nil }
        return String(title[range])
    }

    // MARK: - Input Detection

    /// Detect if terminal is waiting for human input based on content patterns
    private func detectInputWaiting(content: String) -> TerminalStatus? {
        let lines = content.components(separatedBy: "\n")
        guard let lastLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else {
            return nil
        }
        let trimmed = lastLine.trimmingCharacters(in: .whitespaces).lowercased()

        // Interactive prompts: [y/N], (yes/no), Continue?
        if trimmed.hasSuffix("[y/n]") || trimmed.hasSuffix("[y/n]:") ||
           trimmed.hasSuffix("(yes/no)") || trimmed.hasSuffix("(yes/no)?") ||
           trimmed.hasSuffix("continue?") || trimmed.hasSuffix("proceed?") {
            return .actionRequired
        }

        // Password/passphrase prompts
        if trimmed.hasPrefix("password") || trimmed.contains("passphrase") ||
           trimmed.hasPrefix("enter password") || trimmed.hasPrefix("sudo") {
            return .actionRequired
        }

        // REPL prompts waiting for input
        if trimmed.hasSuffix(">>> ") || trimmed.hasSuffix("... ") ||
           trimmed.hasSuffix("irb>") || trimmed.hasSuffix("mysql>") ||
           trimmed.hasSuffix("postgres=>") || trimmed.hasSuffix("sqlite>") {
            return .actionRequired
        }

        // Claude Code waiting (prompt character at end)
        if trimmed.hasSuffix("❯") || trimmed.hasSuffix("❯ ") {
            return .actionRequired
        }

        return nil
    }

    // MARK: - AI Summary Generation

    private func generateAISummaries(
        batch: [(id: String, wid: Int, tidx: Int, content: String, narrative: String)]
    ) -> [(String, String)] {
        var prompt = """
        For each terminal below, give a 1-5 word summary of what the user is working on.
        Focus on the HIGH-LEVEL task, not the specific command visible.
        If history is provided, use it to understand the broader context.
        Reply with ONLY numbered summaries, one per line. No explanations.

        """

        for (i, item) in batch.enumerated() {
            prompt += "\n\(i + 1)."
            if !item.narrative.isEmpty {
                prompt += " [History: \(item.narrative)]"
            }
            // Cap content at 600 chars to keep prompt small
            prompt += "\n\(String(item.content.suffix(600)))\n"
        }

        guard let response = callClaude(prompt: prompt) else {
            return batch.map { ($0.id, "Terminal active") }
        }

        // Parse numbered responses
        let lines = response.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        var results: [(String, String)] = []

        for (i, item) in batch.enumerated() {
            let raw: String
            if i < lines.count {
                raw = lines[i]
                    .replacingOccurrences(of: "^\\s*\\d+\\.?\\s*", with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)
            } else {
                raw = "Terminal active"
            }
            results.append((item.id, raw.isEmpty ? "Terminal active" : raw))
        }

        return results
    }

    private func callClaude(prompt: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "CLAUDECODE= claude -p --model haiku"]

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "CLAUDECODE")
        process.environment = env

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
            inputPipe.fileHandleForWriting.closeFile()

            // Wait with 30s timeout
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
            if group.wait(timeout: .now() + 30) == .timedOut {
                process.terminate()
                print("[SummaryManager] claude timed out")
                return nil
            }

            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == true ? nil : text
        } catch {
            print("[SummaryManager] claude error: \(error)")
            return nil
        }
    }

    // MARK: - Accessors

    func summary(for tabID: String) -> String? {
        let s = contexts[tabID]?.currentSummary
        return (s?.isEmpty == true) ? nil : s
    }

    func method(for tabID: String) -> TerminalContext.SummaryMethod? {
        contexts[tabID]?.summaryMethod
    }

    func lastActivity(for tabID: String) -> Date? {
        let d = contexts[tabID]?.lastChanged
        return d == .distantPast ? nil : d
    }

    func statusOverride(for tabID: String) -> TerminalStatus? {
        contexts[tabID]?.statusOverride
    }

    func context(for tabID: String) -> TerminalContext? {
        contexts[tabID]
    }
}
