import SwiftUI

struct TerminalRowView: View {
    let tab: TerminalTab
    let shortcutIndex: Int
    var isSelected: Bool = false
    let onSelect: () -> Void

    @State private var isHovered = false

    private var isHighlighted: Bool { isHovered || isSelected }

    var body: some View {
        Button(action: onSelect) {
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
                        .opacity(isHighlighted ? 1 : 0.5)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(isHighlighted ? Color.primary.opacity(0.07) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.12), value: isSelected)
    }
}
