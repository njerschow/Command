import SwiftUI

struct ClaudeSetupView: View {
    @Binding var isPresented: Bool
    @State private var copied = false
    @State private var autoConfigDone = false
    @State private var autoConfigError: String?

    private let hookConfig = """
    claude hooks add --scope user Stop '{"type":"http","url":"http://localhost:19220/claude-event"}'
    claude hooks add --scope user Notification '{"type":"http","url":"http://localhost:19220/claude-event"}'
    claude hooks add --scope user PreToolUse '{"type":"http","url":"http://localhost:19220/claude-event"}'
    claude hooks add --scope user SessionStart '{"type":"http","url":"http://localhost:19220/claude-event"}'
    claude hooks add --scope user SessionEnd '{"type":"http","url":"http://localhost:19220/claude-event"}'
    """

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            description
            commandBlock
            actions
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - Sections

    private var header: some View {
        HStack {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.blue)
            Text("Claude Code Integration")
                .font(.system(size: 13, weight: .semibold))
            Spacer()
            Button(action: { isPresented = false }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var description: some View {
        Text("Run these commands to connect Claude Code. The app will show real-time status for your Claude sessions.")
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var commandBlock: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                Text(hookConfig.trimmingCharacters(in: .whitespacesAndNewlines))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(10)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
    }

    private var actions: some View {
        HStack(spacing: 8) {
            copyButton

            Spacer()

            statusLabel
        }
    }

    private var copyButton: some View {
        Button(action: copyToClipboard) {
            HStack(spacing: 4) {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10))
                    .contentTransition(.symbolEffect(.replace))
                Text(copied ? "Copied!" : "Copy commands")
                    .font(.system(size: 11, weight: .medium))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.accentColor.opacity(copied ? 0.15 : 0.1))
            )
        }
        .buttonStyle(.plain)
        .foregroundStyle(copied ? .green : .blue)
    }

    @ViewBuilder
    private var statusLabel: some View {
        if let error = autoConfigError {
            Text(error)
                .font(.system(size: 10))
                .foregroundStyle(.red)
        } else if autoConfigDone {
            HStack(spacing: 2) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 10))
                Text("Connected")
                    .font(.system(size: 10))
            }
            .foregroundStyle(.green)
        }
    }

    // MARK: - Actions

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(
            hookConfig.trimmingCharacters(in: .whitespacesAndNewlines),
            forType: .string
        )
        withAnimation(.spring(duration: 0.2)) {
            copied = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { copied = false }
        }
    }
}
