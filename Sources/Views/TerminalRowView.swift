import SwiftUI

struct TerminalRowView: View {
    let tab: TerminalTab
    let shortcutIndex: Int
    var isSelected: Bool = false
    let onSelect: () -> Void

    @State private var isHovered = false
    @State private var isPressed = false

    private var isHighlighted: Bool { isHovered || isSelected }

    var body: some View {
        Button(action: {
            withAnimation(.spring(duration: 0.15)) {
                isPressed = true
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                withAnimation(.spring(duration: 0.15)) {
                    isPressed = false
                }
            }
            onSelect()
        }) {
            HStack(spacing: 8) {
                StatusDotView(status: tab.status)

                Text(tab.title)
                    .font(.system(size: 13, weight: isHighlighted ? .medium : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 4)

                if shortcutIndex < 9 {
                    Text("⌘\(shortcutIndex + 1)")
                        .font(.system(size: 11, weight: .regular, design: .rounded))
                        .foregroundStyle(.tertiary)
                        .opacity(isHighlighted ? 1 : 0.4)
                }
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

    private var backgroundFill: Color {
        if isPressed {
            return Color.primary.opacity(0.1)
        } else if isHighlighted {
            return Color.primary.opacity(0.06)
        }
        return Color.clear
    }
}
