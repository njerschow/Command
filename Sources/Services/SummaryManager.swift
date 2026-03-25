import Foundation
import Combine

/// Orchestrates terminal summaries: fingerprinting, local heuristics, AI generation, rolling context
final class SummaryManager: ObservableObject {
    @Published var contexts: [String: TerminalContext] = [:]
    @Published var isSummarizing = false

    let contentReader = ContentReader()
    private var timer: Timer?
    private var isRefreshing = false
    private var refreshStartedAt: Date?
    private weak var appState: AppState?
    private var persistTimer: Timer?

    private static let summaryFile: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Command", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("summaries.json")
    }()

    // MARK: - Lifecycle

    func start(appState: AppState) {
        self.appState = appState
        loadPersistedSummaries()

        // First refresh after 3s (let scanner populate terminal list first)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.refresh()
        }

        // Then every 5 minutes
        timer = Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    // MARK: - Persistence

    private func loadPersistedSummaries() {
        guard let data = try? Data(contentsOf: Self.summaryFile),
              let dict = try? JSONDecoder().decode([String: String].self, from: data) else { return }
        for (tabID, summary) in dict {
            var ctx = contexts[tabID] ?? TerminalContext()
            ctx.currentSummary = summary
            ctx.summaryMethod = .aiGenerated
            contexts[tabID] = ctx
        }
        Log.info("loaded \(dict.count) persisted summaries", category: "summary")
    }

    private func persistSummaries() {
        persistTimer?.invalidate()
        persistTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: false) { [weak self] _ in
            guard let self else { return }
            let dict = self.contexts.compactMapValues { ctx -> String? in
                ctx.currentSummary.isEmpty ? nil : ctx.currentSummary
            }
            guard let data = try? JSONEncoder().encode(dict) else { return }
            try? data.write(to: Self.summaryFile, options: .atomic)
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
        // Safety: reset isRefreshing if stuck for over 120s
        if isRefreshing, let started = refreshStartedAt, Date().timeIntervalSince(started) > 120 {
            Log.error("refresh was stuck for >120s, resetting", category: "summary")
            isRefreshing = false
        }
        guard !isRefreshing, let groups = appState?.terminalGroups, !groups.isEmpty else {
            Log.info("refresh skipped: isRefreshing=\(isRefreshing) groups=\(appState?.terminalGroups.count ?? 0)", category: "summary")
            return
        }
        isRefreshing = true
        isSummarizing = true
        refreshStartedAt = Date()
        Log.info("refresh started for \(groups.flatMap(\.tabs).count) tabs", category: "summary")

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
                        tabIndex: tab.tabIndex,
                        app: group.app
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
                guard let self else { return }
                let started = self.refreshStartedAt ?? Date()
                self.contexts = updated
                self.isRefreshing = false
                self.refreshStartedAt = nil
                self.persistSummaries()
                Log.info("refresh complete: \(updated.count) contexts, \(aiBatch.count) AI-summarized", category: "summary")
                // Keep indicator visible for at least 1s so the user can see it
                let elapsed = Date().timeIntervalSince(started)
                let delay = max(0, 1.0 - elapsed)
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    self?.isSummarizing = false
                }
            }
        }
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
        Log.info("callClaude: starting claude -p (prompt \(prompt.count) chars)", category: "summary")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "CLAUDECODE= claude -p --model haiku --no-session-persistence"]

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

            // Read output concurrently to avoid pipe buffer deadlock
            var outputData = Data()
            let readGroup = DispatchGroup()
            readGroup.enter()
            DispatchQueue.global().async {
                outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
                readGroup.leave()
            }

            // Wait with 30s timeout
            let exitGroup = DispatchGroup()
            exitGroup.enter()
            DispatchQueue.global().async { process.waitUntilExit(); exitGroup.leave() }
            if exitGroup.wait(timeout: .now() + 30) == .timedOut {
                Log.error("callClaude: timed out after 30s, killing", category: "summary")
                process.terminate()
                return nil
            }

            readGroup.wait()
            let text = String(data: outputData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.info("callClaude: got response (\(text?.count ?? 0) chars)", category: "summary")
            return text?.isEmpty == true ? nil : text
        } catch {
            Log.error("callClaude: failed to run: \(error)", category: "summary")
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

    func context(for tabID: String) -> TerminalContext? {
        contexts[tabID]
    }
}
