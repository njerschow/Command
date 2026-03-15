import SwiftUI

struct TerminalRowView: View {
    let tab: TerminalTab
    let group: TerminalGroup
    let summary: String?
    let lastActive: Date?
    let context: TerminalContext?
    let shortcutIndex: Int
    var isSelected: Bool = false
    var claudeState: ClaudeState? = nil
    let onSelect: () -> Void
    var onSaveAndClose: (() -> Void)? = nil

    @State private var isHovered = false
    @State private var isPressed = false
    @State private var showInfo = false

    private var isHighlighted: Bool { isHovered || isSelected }

    private var displayTitle: String {
        if let summary, !summary.isEmpty {
            return summary
        }
        return tab.title
    }

    /// Merge process-based status with content-based override
    private var effectiveStatus: TerminalStatus {
        context?.statusOverride ?? tab.status
    }

    var body: some View {
        Button(action: {
            withAnimation(.spring(duration: 0.15)) { isPressed = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(duration: 0.15)) { isPressed = false }
            }
            onSelect()
        }) {
            HStack(spacing: 8) {
                StatusDotView(status: effectiveStatus, claudeState: claudeState)

                Text(displayTitle)
                    .font(.system(size: 13, weight: isHighlighted ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if tab.isClaudeSession || claudeState != nil {
                    Text("claude")
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(Color.primary.opacity(0.06))
                        )
                }

                Spacer(minLength: 4)

                // Info button — only on hover
                if isHovered {
                    infoButton
                }

                trailingView
            }
            .padding(.leading, 6)
            .padding(.trailing, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundFill)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 2)
        .sensoryFeedback(.selection, trigger: isSelected)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(.spring(duration: 0.2, bounce: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .popover(isPresented: $showInfo, arrowEdge: .trailing) {
            InfoPopoverView(tab: tab, context: context, lastActive: lastActive, onSaveAndClose: onSaveAndClose)
        }
    }

    private var infoButton: some View {
        Button(action: { showInfo.toggle() }) {
            Image(systemName: "info.circle")
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .transition(.opacity)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    // Hover: show shortcut. Not hovering: show relative time.
    @ViewBuilder
    private var trailingView: some View {
        if isHovered && shortcutIndex < 9 {
            Text("⌘\(shortcutIndex + 1)")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        } else if let lastActive {
            Text(relativeTime(lastActive))
                .font(.system(size: 11, design: .rounded))
                .foregroundStyle(.tertiary)
                .transition(.opacity)
        }
    }

    private var backgroundFill: Color {
        if isPressed {
            return Color.primary.opacity(0.1)
        } else if isHighlighted {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "now" }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            return "\(m)m ago"
        }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            return "\(h)h ago"
        }
        if seconds < 604800 {
            let d = Int(seconds / 86400)
            return "\(d)d ago"
        }
        let w = Int(seconds / 604800)
        return "\(w)w ago"
    }
}

// MARK: - Info Popover

struct InfoPopoverView: View {
    let tab: TerminalTab
    let context: TerminalContext?
    let lastActive: Date?
    var onSaveAndClose: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Title
            Text(tab.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(2)

            Divider()

            // Summary method
            if let ctx = context {
                infoRow("Summary", ctx.currentSummary.isEmpty ? "—" : ctx.currentSummary)
                infoRow("Method", ctx.summaryMethod.rawValue)
            }

            // Timing
            if let lastActive {
                infoRow("Last active", formatTime(lastActive))
            }
            if let checked = context?.lastChecked, checked != .distantPast {
                infoRow("Last checked", formatTime(checked))
            }

            // Technical
            if let tty = tab.tty, !tty.isEmpty {
                infoRow("TTY", tty)
            }
            infoRow("Status", statusLabel(tab.status))

            // History
            if let ctx = context, !ctx.historyLog.isEmpty {
                Divider()
                Text("History")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                ForEach(ctx.historyLog.indices, id: \.self) { i in
                    let entry = ctx.historyLog[i]
                    HStack(spacing: 4) {
                        Text(shortTime(entry.date))
                            .foregroundStyle(.quaternary)
                        Text(entry.summary)
                            .foregroundStyle(.secondary)
                    }
                    .font(.system(size: 10))
                }
            }

            // Save & Close
            if let onSaveAndClose {
                Divider()
                Button(action: onSaveAndClose) {
                    HStack(spacing: 4) {
                        Image(systemName: "archivebox")
                            .font(.system(size: 10))
                        Text("Save & Close")
                            .font(.system(size: 11, weight: .medium))
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.primary.opacity(0.05))
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(10)
        .frame(width: 220)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
                .frame(width: 70, alignment: .trailing)
            Text(value)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func statusLabel(_ status: TerminalStatus) -> String {
        switch status {
        case .idle: return "Idle"
        case .running: return "Running"
        case .actionRequired: return "Action required"
        }
    }

    private func formatTime(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func shortTime(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }
}
