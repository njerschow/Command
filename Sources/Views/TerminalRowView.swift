import SwiftUI

struct TerminalRowView: View {
    let tab: TerminalTab
    let summary: String?
    let lastActive: Date?
    let shortcutIndex: Int
    var isSelected: Bool = false
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    private var isHighlighted: Bool { isHovered || isSelected }

    private var displayTitle: String {
        if let summary, !summary.isEmpty {
            return summary
        }
        return tab.title
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
                StatusDotView(status: tab.status)

                Text(displayTitle)
                    .font(.system(size: 13, weight: isHighlighted ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                trailingView
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(backgroundFill)
            )
            .scaleEffect(isPressed ? 0.98 : 1.0)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .sensoryFeedback(.selection, trigger: isSelected)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(.spring(duration: 0.2, bounce: 0.1), value: isSelected)
        .animation(.easeOut(duration: 0.12), value: isHovered)
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
                .foregroundStyle(.quaternary)
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
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h" }
        if seconds < 604800 { return "\(Int(seconds / 86400))d" }
        return "\(Int(seconds / 604800))w"
    }
}
