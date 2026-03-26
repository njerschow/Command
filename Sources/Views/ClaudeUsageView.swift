import SwiftUI

struct ClaudeUsageView: View {
    @EnvironmentObject var usageReader: ClaudeUsageReader
    var showDetailed: Bool = false

    @State private var selectedDuration: Duration = .week

    enum Duration: String, CaseIterable {
        case week = "7d"
        case month = "30d"
        case all = "All"

        var dayCount: Int? {
            switch self {
            case .week: return 7
            case .month: return 30
            case .all: return nil
            }
        }
    }

    private var filteredDays: [ClaudeUsageReader.DailyActivity] {
        guard let count = selectedDuration.dayCount else { return usageReader.recentDays }
        return Array(usageReader.recentDays.suffix(count))
    }

    private var periodMessages: Int {
        filteredDays.reduce(0) { $0 + $1.messageCount }
    }

    private var periodSessions: Int {
        filteredDays.reduce(0) { $0 + $1.sessionCount }
    }

    private var periodToolCalls: Int {
        filteredDays.reduce(0) { $0 + $1.toolCallCount }
    }

    var body: some View {
        VStack(spacing: 6) {
            // Always visible: duration picker + bar graph
            if !usageReader.recentDays.isEmpty {
                HStack(spacing: 4) {
                    Text("Activity")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)

                    Spacer()

                    HStack(spacing: 0) {
                        ForEach(Duration.allCases, id: \.self) { duration in
                            Button(action: {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    selectedDuration = duration
                                }
                            }) {
                                Text(duration.rawValue)
                                    .font(.system(size: 9, weight: selectedDuration == duration ? .semibold : .regular))
                                    .foregroundStyle(selectedDuration == duration ? .primary : .tertiary)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .fill(selectedDuration == duration ? Color.primary.opacity(0.08) : Color.clear)
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Period summary
                HStack(spacing: 0) {
                    miniStat(ClaudeUsageReader.formatTokens(periodMessages), "msgs")
                    miniStat("\(periodSessions)", "sessions")
                    miniStat(ClaudeUsageReader.formatTokens(periodToolCalls), "tools")
                }

                // Bar graph
                BarGraphView(days: filteredDays)
                    .frame(height: 60)
            }

            // Detailed: model breakdown + totals
            if showDetailed {
                Divider()

                HStack(spacing: 0) {
                    statCell("Sessions", "\(usageReader.totalSessions)")
                    statCell("Messages", ClaudeUsageReader.formatTokens(usageReader.totalMessages))
                    statCell("Days", "\(daysActive)")
                }

                Divider()

                ForEach(usageReader.modelStats, id: \.name) { model in
                    HStack(spacing: 6) {
                        Text(model.name)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 70, alignment: .leading)

                        GeometryReader { geo in
                            let maxTokens = usageReader.modelStats.first?.totalTokens ?? 1
                            let ratio = min(1.0, Double(model.totalTokens) / Double(max(1, maxTokens)))
                            RoundedRectangle(cornerRadius: 2, style: .continuous)
                                .fill(barColor(for: model.name))
                                .frame(width: geo.size.width * ratio)
                        }
                        .frame(height: 6)

                        Text(ClaudeUsageReader.formatTokens(model.totalTokens))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .frame(width: 50, alignment: .trailing)
                    }
                    .frame(height: 14)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var daysActive: Int {
        guard let first = usageReader.firstSessionDate else { return 0 }
        return max(1, Calendar.current.dateComponents([.day], from: first, to: Date()).day ?? 1)
    }

    private func statCell(_ label: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.system(size: 16, weight: .semibold, design: .rounded))
                .foregroundStyle(.primary)
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity)
    }

    private func miniStat(_ value: String, _ label: String) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.primary.opacity(0.7))
            Text(label)
                .font(.system(size: 9))
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity)
    }

    private func barColor(for model: String) -> Color {
        if model.contains("Opus") { return .blue.opacity(0.7) }
        if model.contains("Sonnet") { return .blue.opacity(0.6) }
        if model.contains("Haiku") { return .green.opacity(0.6) }
        return .secondary.opacity(0.4)
    }
}

// MARK: - Bar Graph

private struct BarGraphView: View {
    let days: [ClaudeUsageReader.DailyActivity]

    @State private var hoverIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            let values = days.map { $0.messageCount }
            let maxVal = max(1, values.max() ?? 1)
            let count = max(1, values.count)
            let barWidth = max(2, (geo.size.width - CGFloat(count - 1) * 1.5) / CGFloat(count))
            let h = geo.size.height

            ZStack(alignment: .bottom) {
                HStack(alignment: .bottom, spacing: 1.5) {
                    ForEach(Array(values.enumerated()), id: \.offset) { i, val in
                        let barH = max(1, h * CGFloat(val) / CGFloat(maxVal))
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .fill(hoverIndex == i ? Color(red: 0.3, green: 0.5, blue: 1.0) : Color(red: 0.3, green: 0.5, blue: 1.0).opacity(0.65))
                            .frame(width: barWidth, height: barH)
                    }
                }

                // Hover tooltip
                if let idx = hoverIndex, idx < days.count {
                    let day = days[idx]
                    let barStep = (barWidth + 1.5)
                    let x = barStep * CGFloat(idx) + barWidth / 2
                    let tooltipX = min(max(50, x), geo.size.width - 50)

                    VStack(spacing: 1) {
                        Text(shortDate(day.date))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.primary.opacity(0.7))
                        HStack(spacing: 4) {
                            Text("\(day.messageCount) msgs")
                            Text("·")
                            Text("\(day.sessionCount) sess")
                        }
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .position(x: tooltipX, y: -12)
                }
            }
            .overlay {
                GeometryReader { geo2 in
                    Color.clear
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                let step = geo2.size.width / CGFloat(count)
                                let idx = Int(loc.x / step)
                                hoverIndex = max(0, min(count - 1, idx))
                            case .ended:
                                hoverIndex = nil
                            }
                        }
                }
            }
        }
        .padding(.top, 16) // room for tooltip
    }

    private func shortDate(_ dateStr: String) -> String {
        let parts = dateStr.split(separator: "-")
        guard parts.count == 3,
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return dateStr }
        let months = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun",
                       "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        guard month >= 1 && month <= 12 else { return dateStr }
        return "\(months[month]) \(day)"
    }
}

// MARK: - Rate Limit Bar (always visible)

struct RateLimitBar: View {
    @EnvironmentObject var usageReader: ClaudeUsageReader

    var body: some View {
        if let rl = usageReader.rateLimits {
            HStack(spacing: 12) {
                gauge("5h", rl.dailyUtilization, reset: rl.dailyReset)
                gauge("7d", rl.weeklyUtilization, reset: rl.weeklyReset)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private func gauge(_ label: String, _ utilization: Double, reset: Date?) -> some View {
        VStack(spacing: 3) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text("\(Int(utilization * 100))%")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(utilization > 0.8 ? .red : .primary.opacity(0.7))
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(Color.primary.opacity(0.06))
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(utilization > 0.8 ? Color.red.opacity(0.6) : Color.blue.opacity(0.5))
                        .frame(width: geo.size.width * min(1, utilization))
                }
            }
            .frame(height: 4)
            if let reset {
                Text("resets \(resetLabel(reset))")
                    .font(.system(size: 8))
                    .foregroundStyle(.quaternary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func resetLabel(_ date: Date) -> String {
        let seconds = date.timeIntervalSinceNow
        if seconds <= 0 { return "soon" }
        if seconds < 3600 {
            return "in \(Int(seconds / 60))m"
        }
        return "in \(Int(seconds / 3600))h \(Int(seconds.truncatingRemainder(dividingBy: 3600) / 60))m"
    }
}
