import SwiftUI
import AVKit

struct UpdatePopoverView: View {
    @EnvironmentObject var updateChecker: UpdateChecker

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header
            HStack {
                Image(systemName: "arrow.up.circle.fill")
                    .foregroundStyle(.blue)
                    .font(.system(size: 16))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update Available")
                        .font(.system(size: 13, weight: .semibold))
                    Text("v\(updateChecker.currentVersion) → v\(updateChecker.latestVersion ?? "")")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            Divider()

            // Video preview if available
            if let videoURLString = updateChecker.releaseVideoURL,
               let videoURL = URL(string: videoURLString) {
                VideoPlayerView(url: videoURL)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            // Release notes
            if let notes = updateChecker.releaseNotes {
                let cleaned = Self.stripVideoMarkdown(notes)
                if !cleaned.isEmpty {
                    ScrollView {
                        Text(Self.renderMarkdownPlain(cleaned))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 150)
                }
            }

            // Action buttons
            HStack(spacing: 8) {
                if let downloadURL = updateChecker.downloadURL,
                   let url = URL(string: downloadURL) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Text("Download")
                            .font(.system(size: 12, weight: .medium))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }

                if let releaseURL = updateChecker.releaseURL,
                   let url = URL(string: releaseURL) {
                    Button(action: { NSWorkspace.shared.open(url) }) {
                        Text("View on GitHub")
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// Remove video embeds from release notes so we don't show them twice
    static func stripVideoMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<video") && t.contains("</video>") { return false }
            if t.hasPrefix("<video") || t == "</video>" { return false }
            if (t.hasSuffix(".mp4") || t.hasSuffix(".mov")) && t.hasPrefix("http") { return false }
            if t.range(of: #"!\[[^\]]*\]\([^)]+\.(?:mp4|mov)\)"#, options: .regularExpression) != nil { return false }
            return true
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Simple markdown to plain text (strip #, *, -, links)
    static func renderMarkdownPlain(_ text: String) -> String {
        var result = text
        // Strip heading markers
        result = result.replacingOccurrences(of: #"^#{1,6}\s+"#, with: "", options: .regularExpression)
        // Strip bold/italic markers
        result = result.replacingOccurrences(of: "**", with: "")
        result = result.replacingOccurrences(of: "__", with: "")
        // Convert [text](url) -> text
        result = result.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)
        return result
    }
}

/// AVPlayer wrapper for video preview
struct VideoPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        let player = AVPlayer(url: url)
        player.isMuted = true
        view.player = player
        view.controlsStyle = .inline
        view.showsFullScreenToggleButton = false
        player.play()
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}
