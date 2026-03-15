import Foundation
import Combine

/// Two-mode session search: instant keyword scoring + async Claude AI search
final class SessionSearcher: ObservableObject {
    @Published var keywordResults: [ScoredSession] = []
    @Published var aiResults: [SavedSession] = []
    @Published var isAISearching = false

    private var aiTask: Process?
    private var debounceTimer: Timer?

    deinit {
        debounceTimer?.invalidate()
        aiTask?.terminate()
    }

    struct ScoredSession: Identifiable {
        let session: SavedSession
        let score: Double
        var id: String { session.id }
    }

    // MARK: - Keyword Search (instant)

    func keywordSearch(query: String, sessions: [SavedSession]) {
        guard !query.isEmpty else {
            keywordResults = []
            return
        }

        let q = query.lowercased()
        let scored = sessions.compactMap { session -> ScoredSession? in
            let score = self.score(session: session, query: q)
            return score > 0 ? ScoredSession(session: session, score: score) : nil
        }.sorted { $0.score > $1.score }

        keywordResults = scored
    }

    private func score(session: SavedSession, query: String) -> Double {
        var total: Double = 0

        let title = session.summary.lowercased()
        let dir = (session.workingDirectory ?? "").lowercased()
        let tag = session.effectiveTag.lowercased()

        // Title scoring
        if title == query { total += 120 }
        else if title.hasPrefix(query) { total += 100 }
        else if wordBoundaryMatch(query, in: title) { total += 60 }
        else if title.contains(query) { total += 30 }

        // Tag exact match
        if tag == query { total += 80 }

        // Directory scoring
        if dir.contains(query) { total += 25 }
        if wordBoundaryMatch(query, in: dir) { total += 15 }

        // Content scoring (search through terminal output)
        if let content = session.content?.lowercased() {
            if wordBoundaryMatch(query, in: content) { total += 20 }
            else if content.contains(query) { total += 8 }
        }

        // Recency tiebreaker (0-5 points, most recent = 5) — only if something matched
        if total > 0 {
            let age = -session.closedAt.timeIntervalSinceNow
            let maxAge: TimeInterval = 7 * 86400 // 1 week
            let recency = max(0, min(5, 5 * (1 - age / maxAge)))
            total += recency
        }

        return total
    }

    /// Check if query matches at a word boundary in text
    private func wordBoundaryMatch(_ query: String, in text: String) -> Bool {
        let queryChars = Array(query)
        let textChars = Array(text)
        guard queryChars.count <= textChars.count else { return false }
        for i in 0..<textChars.count {
            let isStart = i == 0 || !textChars[i - 1].isLetter
            if isStart && textChars[i...].starts(with: queryChars) {
                return true
            }
        }
        return false
    }

    // MARK: - AI Search (async, debounced)

    func aiSearch(query: String, sessions: [SavedSession]) {
        cancelAISearch()

        guard query.count >= 3 else {
            aiResults = []
            return
        }

        // Debounce 500ms
        debounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.runAISearch(query: query, sessions: sessions)
        }
    }

    func cancelAISearch() {
        debounceTimer?.invalidate()
        debounceTimer = nil
        aiTask?.terminate()
        aiTask = nil
        isAISearching = false
    }

    private func runAISearch(query: String, sessions: [SavedSession]) {
        guard !sessions.isEmpty else { return }
        isAISearching = true

        let sessionsById = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })

        // Build prompt with session summaries + content snippets
        var prompt = """
        You are a search engine for terminal session history. The user is searching for: "\(query)"

        Here are the saved sessions. Return ONLY a JSON array of matching session IDs, ranked by relevance (most relevant first). Return [] if nothing matches.

        Sessions:
        """

        for session in sessions {
            prompt += "\n\n---\nID: \(session.id)"
            prompt += "\nSummary: \(session.summary)"
            prompt += "\nTag: \(session.effectiveTag)"
            if let dir = session.workingDirectory { prompt += "\nDirectory: \(dir)" }
            prompt += "\nClosed: \(session.closedAt)"
            if let content = session.content {
                // Send first 100 + last 100 lines to keep prompt manageable
                let lines = content.components(separatedBy: "\n")
                let snippet: String
                if lines.count <= 200 {
                    snippet = content
                } else {
                    let head = lines.prefix(100).joined(separator: "\n")
                    let tail = lines.suffix(100).joined(separator: "\n")
                    snippet = head + "\n...\n" + tail
                }
                prompt += "\nContent:\n\(snippet)"
            }
        }

        prompt += "\n\n---\nReturn ONLY a JSON array of IDs, e.g. [\"id1\",\"id2\"]. No explanation."

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let result = self?.callClaude(prompt: prompt)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isAISearching else { return }
                self.isAISearching = false

                guard let result,
                      let data = result.data(using: .utf8),
                      let ids = try? JSONDecoder().decode([String].self, from: data) else {
                    self.aiResults = []
                    return
                }

                self.aiResults = ids.compactMap { sessionsById[$0] }
            }
        }
    }

    private func callClaude(prompt: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "CLAUDECODE= claude -p --model sonnet"]

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
            self.aiTask = process
            inputPipe.fileHandleForWriting.write(Data(prompt.utf8))
            inputPipe.fileHandleForWriting.closeFile()

            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global().async { process.waitUntilExit(); group.leave() }
            if group.wait(timeout: .now() + 30) == .timedOut {
                process.terminate()
                self.aiTask = nil
                return nil
            }

            self.aiTask = nil
            let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
            let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)

            // Extract JSON array from response (Claude might wrap it in markdown)
            if let text, let start = text.firstIndex(of: "["), let end = text.lastIndex(of: "]") {
                return String(text[start...end])
            }
            return text?.isEmpty == true ? nil : text
        } catch {
            self.aiTask = nil
            return nil
        }
    }
}
