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
        case "openclaw": return .green.opacity(0.9)
        case "claude": return .purple.opacity(0.85)
        case "ssh": return .primary.opacity(0.6)
        case "vim", "nvim", "emacs": return .green.opacity(0.85)
        case "node", "npm": return .green.opacity(0.8)
        case "python": return .blue.opacity(0.8)
        case "cargo": return .orange.opacity(0.8)
        case "docker": return .cyan.opacity(0.85)
        case "git": return .red.opacity(0.8)
        case "make": return .yellow.opacity(0.85)
        case "autopilot": return AutopilotStyle.activeColor
        default: return .primary.opacity(0.5)
        }
    }

    private var backgroundColor: Color {
        foregroundColor.opacity(0.15)
    }
}
