import Foundation

/// Tracks rolling context for a single terminal tab's summary
struct TerminalContext {
    var currentSummary: String = ""
    var summaryMethod: SummaryMethod = .processName
    var historyLog: [(date: Date, summary: String)] = []
    var lastFingerprint: String = ""
    var lastChecked: Date = .distantPast
    var lastChanged: Date = .distantPast
    var lastSummarized: Date = .distantPast
    var unchangedCount: Int = 0

    /// Content-based status override (e.g., detected input prompt)
    var statusOverride: TerminalStatus? = nil

    enum SummaryMethod: String {
        case localHeuristic = "Local heuristic"
        case aiGenerated = "AI (Haiku)"
        case windowTitle = "Window title"
        case processName = "Process detection"
        case idle = "Idle detection"
    }

    mutating func pushHistory(_ summary: String) {
        guard !summary.isEmpty else { return }
        if historyLog.last?.summary == summary { return }
        historyLog.append((Date(), summary))
        if historyLog.count > 5 {
            historyLog.removeFirst(historyLog.count - 5)
        }
    }

    /// Narrative context for AI prompt — shows what's been happening
    var narrativeContext: String {
        guard !historyLog.isEmpty else { return "" }
        return historyLog.map { $0.summary }.joined(separator: " → ")
    }
}
