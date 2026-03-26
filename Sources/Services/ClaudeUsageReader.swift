import Foundation
import Combine

/// Reads Claude Code usage stats from ~/.claude/stats-cache.json
final class ClaudeUsageReader: ObservableObject {

    struct ModelStats: Equatable {
        let name: String
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
        var totalTokens: Int { inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens }
    }

    struct DailyActivity: Equatable {
        let date: String
        let messageCount: Int
        let sessionCount: Int
        let toolCallCount: Int
    }

    struct RateLimitInfo: Equatable {
        let dailyUtilization: Double    // 0.0–1.0
        let weeklyUtilization: Double   // 0.0–1.0
        let dailyReset: Date?
        let weeklyReset: Date?
    }

    @Published var totalSessions: Int = 0
    @Published var totalMessages: Int = 0
    @Published var modelStats: [ModelStats] = []
    @Published var recentDays: [DailyActivity] = []
    @Published var firstSessionDate: Date? = nil
    @Published var lastUpdated: String = ""
    @Published var rateLimits: RateLimitInfo? = nil

    private var lastRateLimitFetch: Date = .distantPast
    private static let rateLimitInterval: TimeInterval = 300 // 5 minutes

    private let statsURL: URL = {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/stats-cache.json")
    }()

    private var fileMonitor: DispatchSourceFileSystemObject?

    init() {
        reload()
        watchFile()
        refreshRateLimits()
    }

    deinit {
        fileMonitor?.cancel()
    }

    func reload() {
        guard let data = try? Data(contentsOf: statsURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }

        totalSessions = json["totalSessions"] as? Int ?? 0
        totalMessages = json["totalMessages"] as? Int ?? 0
        lastUpdated = json["lastComputedDate"] as? String ?? ""

        if let dateStr = json["firstSessionDate"] as? String {
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            firstSessionDate = f.date(from: dateStr)
        }

        // Parse model usage
        if let usage = json["modelUsage"] as? [String: [String: Any]] {
            modelStats = usage.map { (model, stats) in
                ModelStats(
                    name: Self.shortModelName(model),
                    inputTokens: stats["inputTokens"] as? Int ?? 0,
                    outputTokens: stats["outputTokens"] as? Int ?? 0,
                    cacheReadTokens: stats["cacheReadInputTokens"] as? Int ?? 0,
                    cacheCreationTokens: stats["cacheCreationInputTokens"] as? Int ?? 0
                )
            }.sorted { $0.totalTokens > $1.totalTokens }
        }

        // Parse all daily activity
        if let daily = json["dailyActivity"] as? [[String: Any]] {
            recentDays = daily.map { entry in
                DailyActivity(
                    date: entry["date"] as? String ?? "",
                    messageCount: entry["messageCount"] as? Int ?? 0,
                    sessionCount: entry["sessionCount"] as? Int ?? 0,
                    toolCallCount: entry["toolCallCount"] as? Int ?? 0
                )
            }
        }
    }

    private func watchFile() {
        guard FileManager.default.fileExists(atPath: statsURL.path) else { return }
        let fd = open(statsURL.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .rename],
            queue: .global(qos: .utility)
        )
        source.setEventHandler { [weak self] in
            DispatchQueue.main.async { self?.reload() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        fileMonitor = source
    }

    static func shortModelName(_ full: String) -> String {
        if full.contains("opus-4-6") { return "Opus 4.6" }
        if full.contains("opus-4-5") { return "Opus 4.5" }
        if full.contains("sonnet-4-5") { return "Sonnet 4.5" }
        if full.contains("sonnet-4-6") { return "Sonnet 4.6" }
        if full.contains("sonnet-4-") { return "Sonnet 4" }
        if full.contains("haiku") { return "Haiku" }
        return full
    }

    /// Fetch rate limits from API — throttled to once per 5 minutes
    func refreshRateLimits() {
        let now = Date()
        guard now.timeIntervalSince(lastRateLimitFetch) >= Self.rateLimitInterval else { return }
        lastRateLimitFetch = now

        DispatchQueue.global(qos: .utility).async {
            guard let token = Self.readOAuthToken() else {
                Log.info("rateLimits: failed to read OAuth token", category: "usage")
                return
            }
            Log.info("rateLimits: fetching (token=\(token.prefix(12))…)", category: "usage")

            var request = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
            request.httpMethod = "POST"
            request.setValue(token, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            // Minimal valid request to get rate limit headers back
            let body: [String: Any] = [
                "model": "claude-haiku-4-5-20251001",
                "max_tokens": 1,
                "messages": [["role": "user", "content": "."]]
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)

            let task = URLSession.shared.dataTask(with: request) { [weak self] _, response, error in
                if let error {
                    Log.info("rateLimits: network error: \(error.localizedDescription)", category: "usage")
                    return
                }
                guard let http = response as? HTTPURLResponse else { return }
                Log.info("rateLimits: HTTP \(http.statusCode)", category: "usage")
                let headers = http.allHeaderFields

                let daily = Self.parseUtilization(headers, prefix: "anthropic-ratelimit-unified-5h")
                    ?? Self.parseUtilization(headers, prefix: "anthropic-ratelimit-requests-5h")
                let weekly = Self.parseUtilization(headers, prefix: "anthropic-ratelimit-unified-7d")
                    ?? Self.parseUtilization(headers, prefix: "anthropic-ratelimit-requests-7d")

                let dailyReset = Self.parseReset(headers, prefix: "anthropic-ratelimit-unified-5h")
                    ?? Self.parseReset(headers, prefix: "anthropic-ratelimit-requests-5h")
                let weeklyReset = Self.parseReset(headers, prefix: "anthropic-ratelimit-unified-7d")
                    ?? Self.parseReset(headers, prefix: "anthropic-ratelimit-requests-7d")

                Log.info("rateLimits: daily=\(daily.map { String($0) } ?? "nil") weekly=\(weekly.map { String($0) } ?? "nil")", category: "usage")
                if daily != nil || weekly != nil {
                    let info = RateLimitInfo(
                        dailyUtilization: daily ?? 0,
                        weeklyUtilization: weekly ?? 0,
                        dailyReset: dailyReset,
                        weeklyReset: weeklyReset
                    )
                    DispatchQueue.main.async {
                        self?.rateLimits = info
                    }
                }
            }
            task.resume()
        }
    }

    private static func readOAuthToken() -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        proc.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do {
            try proc.run()
            proc.waitUntilExit()
        } catch { return nil }
        guard proc.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = json["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        return token
    }

    private static func parseUtilization(_ headers: [AnyHashable: Any], prefix: String) -> Double? {
        let key = "\(prefix)-utilization"
        if let val = headers[key] as? String, let d = Double(val) { return d }
        // Case-insensitive fallback
        for (k, v) in headers {
            if let ks = k as? String, ks.lowercased() == key.lowercased(),
               let vs = v as? String, let d = Double(vs) { return d }
        }
        return nil
    }

    private static func parseReset(_ headers: [AnyHashable: Any], prefix: String) -> Date? {
        let key = "\(prefix)-reset"
        var value: String?
        if let val = headers[key] as? String { value = val }
        if value == nil {
            for (k, v) in headers {
                if let ks = k as? String, ks.lowercased() == key.lowercased(),
                   let vs = v as? String { value = vs; break }
            }
        }
        guard let value else { return nil }
        // Try unix timestamp first (API returns these)
        if let ts = TimeInterval(value), ts > 1_000_000_000 {
            return Date(timeIntervalSince1970: ts)
        }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: value) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: value)
    }

    static func formatTokens(_ count: Int) -> String {
        if count >= 1_000_000_000 {
            return String(format: "%.1fB", Double(count) / 1_000_000_000)
        }
        if count >= 1_000_000 {
            return String(format: "%.1fM", Double(count) / 1_000_000)
        }
        if count >= 1_000 {
            return String(format: "%.1fK", Double(count) / 1_000)
        }
        return "\(count)"
    }

}
