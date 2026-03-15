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
            var aiBatch: [(id: String, wid: Int, tidx: Int, content: String, narrative: String, title: String)] = []
            var activeIDs = Set<String>()

            for group in groups {
                for tab in group.tabs {
                    activeIDs.insert(tab.id)
                    var ctx = updated[tab.id] ?? TerminalContext()
                    let isFirstCheck = ctx.lastChecked == .distantPast

                    // Read content for every tab
                    guard let content = self.contentReader.readHistory(
                        windowID: group.windowID,
                        tabIndex: tab.tabIndex
                    ) else {
                        // Can't read content — use title as fallback
                        if ctx.currentSummary.isEmpty {
                            ctx.currentSummary = tab.title
                            ctx.summaryMethod = .windowTitle
                        }
                        ctx.lastChecked = Date()
                        updated[tab.id] = ctx
                        continue
                    }

                    let last10 = ContentNormalizer.lastLines(content, count: 10)
                    let fp = ContentNormalizer.fingerprint(last10)
                    ctx.lastChecked = Date()

                    // ONLY skip if content is truly unchanged AND we already have a summary
                    if fp == ctx.lastFingerprint && !ctx.currentSummary.isEmpty {
                        ctx.unchangedCount += 1
                        updated[tab.id] = ctx
                        continue
                    }

                    // Content changed (or first check) — always go to AI
                    ctx.unchangedCount = 0
                    ctx.lastFingerprint = fp
                    if !isFirstCheck {
                        ctx.lastChanged = Date()
                    }
                    ctx.statusOverride = self.detectInputWaiting(content: content)

                    // Queue for AI — always use Claude for summaries
                    aiBatch.append((
                        tab.id, group.windowID, tab.tabIndex,
                        ContentNormalizer.normalize(content),
                        ctx.narrativeContext,
                        tab.title
                    ))
                    updated[tab.id] = ctx
                }
            }

            // Prune orphaned contexts
            for key in updated.keys where !activeIDs.contains(key) {
                updated.removeValue(forKey: key)
            }

            // Batch AI summaries — the primary summarization path
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
        batch: [(id: String, wid: Int, tidx: Int, content: String, narrative: String, title: String)]
    ) -> [(String, String)] {
        var prompt = """
        IMPORTANT: For each terminal, extract the ONE unique identifying detail — the specific project name, \
        file, service, repo, or task that makes this session distinct. Use 1-5 words. \
        The summary should trigger instant recognition ("oh, that's my X terminal").

        Rules:
        - Pick the most SPECIFIC detail: "Command menubar app" not "Swift project", "nginx config" not "editing files"
        - If it's a Claude Code session, name what it's building/fixing, not that it's Claude
        - If idle, describe what was last happening — the idle state is shown separately
        - If history is provided, use it to understand the broader arc
        - Reply with ONLY numbered summaries, one per line. No explanations.

        """

        for (i, item) in batch.enumerated() {
            prompt += "\n\(i + 1). [Window: \(item.title)]"
            if !item.narrative.isEmpty {
                prompt += " [History: \(item.narrative)]"
            }
            // Send last 100 lines for context
            let contentLines = item.content.components(separatedBy: "\n")
            let last100 = contentLines.suffix(100).joined(separator: "\n")
            prompt += "\n\(last100)\n"
        }

        // Reinforce at the end
        prompt += "\nREMEMBER: Extract the unique identifying keyword/detail for each terminal. Be specific, not generic."

        guard let response = callClaude(prompt: prompt) else {
            // Fallback: use window titles instead of generic "Terminal active"
            return batch.map { ($0.id, $0.title) }
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
                raw = item.title  // Fallback to title, not generic text
            }
            results.append((item.id, raw.isEmpty ? item.title : raw))
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
