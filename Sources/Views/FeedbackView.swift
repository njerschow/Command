import SwiftUI

struct FeedbackView: View {
    var body: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/njerschow/Command/issues") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                Text("Feedback")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }
}

struct FeedbackPopoverView: View {
    /// Persists feedback text across popover opens until explicitly cleared
    @AppStorage("pendingFeedback") private var feedbackText = ""
    @State private var copied = false

    private var ghCommand: String {
        let escaped = feedbackText
            .replacingOccurrences(of: "'", with: "'\\''")
        return "gh issue create --repo njerschow/Command --title 'Feedback' --body '\(escaped)'"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Send Feedback")
                .font(.system(size: 13, weight: .semibold))

            TextEditor(text: $feedbackText)
                .font(.system(size: 12))
                .frame(height: 80)
                .scrollContentBackground(.hidden)
                .padding(4)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .overlay(alignment: .topLeading) {
                    if feedbackText.isEmpty {
                        Text("Describe the issue or suggestion...")
                            .font(.system(size: 12))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 8)
                            .allowsHitTesting(false)
                    }
                }

            if !feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                // Command preview — click to copy
                Button(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ghCommand, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                }) {
                    Text(ghCommand)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .padding(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .fill(Color.primary.opacity(0.03))
                        )
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
            }

            HStack(spacing: 8) {
                Button(action: {
                    let escaped = ghCommand
                        .replacingOccurrences(of: "\\", with: "\\\\")
                        .replacingOccurrences(of: "\"", with: "\\\"")
                    let script = """
                    tell application "Terminal"
                        activate
                        do script "\(escaped)"
                    end tell
                    """
                    var error: NSDictionary?
                    NSAppleScript(source: script)?.executeAndReturnError(&error)
                    feedbackText = ""
                }) {
                    HStack(spacing: 3) {
                        Image(systemName: "terminal")
                            .font(.system(size: 9))
                        Text("Run this in terminal")
                            .font(.system(size: 11, weight: .medium))
                    }
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(feedbackText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button(action: {
                    if let url = URL(string: "https://github.com/njerschow/Command/issues") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text("Browse issues")
                        .font(.system(size: 11))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
        .padding(12)
        .frame(width: 280)
    }
}
