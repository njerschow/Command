import SwiftUI

struct ClaudeSetupView: View {
    @Binding var isPresented: Bool
    @State private var configState: ConfigState = .ready

    enum ConfigState: Equatable {
        case ready
        case done
        case alreadyConfigured
        case error(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            description
            previewBlock
            actions
        }
        .padding(16)
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear { checkExisting() }
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
            Button(action: { withAnimation(.spring(duration: 0.2)) { isPresented = false } }) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
        }
    }

    private var description: some View {
        Group {
            switch configState {
            case .alreadyConfigured:
                Text("Claude Code hooks are already configured. Command will show real-time status for your Claude sessions.")
            case .done:
                Text("Done! Claude Code will now send status updates to Command. Restart any running Claude sessions to activate.")
            default:
                Text("This adds HTTP hooks to your Claude Code settings so Command can show real-time session status.")
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var previewBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Adds to ~/.claude/settings.json:")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            ScrollView(.vertical, showsIndicators: false) {
                Text(previewJSON)
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 120)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            mainButton
            Spacer()
            statusIcon
        }
    }

    @ViewBuilder
    private var mainButton: some View {
        switch configState {
        case .ready:
            Button(action: configure) {
                buttonLabel(icon: "plus.circle.fill", text: "Add hooks to settings")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.blue)
        case .done:
            Button(action: {}) {
                buttonLabel(icon: "checkmark.circle.fill", text: "Configured!")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .disabled(true)
        case .alreadyConfigured:
            Button(action: {}) {
                buttonLabel(icon: "checkmark.circle.fill", text: "Already set up")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.green)
            .disabled(true)
        case .error(let msg):
            Button(action: configure) {
                buttonLabel(icon: "exclamationmark.circle.fill", text: "Retry")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.red)
            .help(msg)
        }
    }

    private func buttonLabel(icon: String, text: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .contentTransition(.symbolEffect(.replace))
            Text(text)
                .font(.system(size: 11, weight: .medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.1))
        )
    }

    @ViewBuilder
    private var statusIcon: some View {
        if case .error(let msg) = configState {
            Text(msg)
                .font(.system(size: 10))
                .foregroundStyle(.red)
                .lineLimit(2)
                .frame(maxWidth: 140)
        }
    }

    // MARK: - Preview JSON

    private let previewJSON = """
    "hooks": {
      "Stop": [{"hooks":[{"type":"http",
        "url":"http://localhost:19220/claude-event"}]}],
      "Notification": [...],
      "PreToolUse": [...],
      "SessionStart": [...],
      "SessionEnd": [...]
    }
    """

    // MARK: - Logic

    private func checkExisting() {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path
        guard let data = FileManager.default.contents(atPath: settingsPath),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any] else { return }

        // Check if our hooks are already there
        if hasOurHook(in: hooks, event: "Stop") {
            configState = .alreadyConfigured
        }
    }

    private func hasOurHook(in hooks: [String: Any], event: String) -> Bool {
        guard let eventHooks = hooks[event] as? [[String: Any]] else { return false }
        for group in eventHooks {
            if let innerHooks = group["hooks"] as? [[String: Any]] {
                for hook in innerHooks {
                    if let url = hook["url"] as? String, url.contains("19220") {
                        return true
                    }
                }
            }
        }
        return false
    }

    private func configure() {
        let settingsPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json").path

        do {
            // Read existing settings
            var settings: [String: Any] = [:]
            if let data = FileManager.default.contents(atPath: settingsPath),
               let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                settings = existing
            }

            // Get or create hooks dict
            var hooks = settings["hooks"] as? [String: Any] ?? [:]

            let hookEntry: [String: Any] = [
                "hooks": [["type": "http", "url": "http://localhost:19220/claude-event"]]
            ]

            // Add our hook to each event (don't overwrite existing hooks)
            for event in ["Stop", "Notification", "PreToolUse", "SessionStart", "SessionEnd"] {
                if hasOurHook(in: hooks, event: event) { continue }

                var eventHooks = hooks[event] as? [[String: Any]] ?? []
                eventHooks.append(hookEntry)
                hooks[event] = eventHooks
            }

            settings["hooks"] = hooks

            // Write back
            let data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: URL(fileURLWithPath: settingsPath))

            withAnimation(.spring(duration: 0.3)) {
                configState = .done
            }
        } catch {
            withAnimation {
                configState = .error(error.localizedDescription)
            }
        }
    }
}
