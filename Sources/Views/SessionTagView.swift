import SwiftUI

/// Compact tag badge showing the session type (claude, ssh, vim, term, etc.)
struct SessionTagView: View {
    let tag: String

    var body: some View {
        Text(tag)
            .font(.system(size: 9, weight: .medium, design: .monospaced))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .fill(backgroundColor)
            )
    }

    private var foregroundColor: Color {
        switch tag {
        case "openclaw": return .green.opacity(0.7)
        case "claude": return .purple.opacity(0.7)
        case "ssh": return .secondary
        case "vim", "nvim", "emacs": return .green.opacity(0.7)
        case "node", "npm": return .green.opacity(0.6)
        case "python": return .blue.opacity(0.6)
        case "cargo": return .orange.opacity(0.6)
        case "docker": return .cyan.opacity(0.7)
        case "git": return .red.opacity(0.6)
        case "make": return .yellow.opacity(0.7)
        default: return .secondary.opacity(0.6)
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.12)
    }
}
