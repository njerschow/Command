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

            // Media preview: video takes priority, then image
            if let videoURLString = updateChecker.releaseVideoURL,
               let videoURL = URL(string: videoURLString) {
                VideoPlayerView(url: videoURL)
                    .frame(height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            } else if let imageURLString = updateChecker.releaseImageURL,
                      let imageURL = URL(string: imageURLString) {
                AsyncImage(url: imageURL) { phase in
                    switch phase {
                    case .success(let image):
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    case .failure:
                        EmptyView()
                    default:
                        ProgressView()
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(maxHeight: 200)
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

            // Install commands
            VStack(alignment: .leading, spacing: 4) {
                Text("To update:")
                    .font(.system(size: 11, weight: .medium))

                let commands = "cd \(repoPath)\ngit pull origin main\nmake run"
                Text(commands)
                    .font(.system(size: 10, design: .monospaced))
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .textSelection(.enabled)

                HStack(spacing: 8) {
                    Button(action: { copyToClipboard(commands) }) {
                        HStack(spacing: 3) {
                            Image(systemName: "doc.on.doc")
                                .font(.system(size: 9))
                            Text("Copy")
                                .font(.system(size: 11))
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if let releaseURL = updateChecker.releaseURL,
                       let url = URL(string: releaseURL) {
                        Button(action: { NSWorkspace.shared.open(url) }) {
                            Text("Release Notes")
                                .font(.system(size: 11))
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: 300)
    }

    /// Detect repo path from app bundle location
    /// No filesystem access — avoids TCC prompts when app is in ~/Documents
    private var repoPath: String {
        // App bundle's grandparent: build/Command.app → build → repo root
        let bundlePath = Bundle.main.bundlePath
        let buildDir = (bundlePath as NSString).deletingLastPathComponent
        return (buildDir as NSString).deletingLastPathComponent
    }

    private func copyToClipboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Remove video/image embeds from release notes so we don't show them twice
    static func stripVideoMarkdown(_ text: String) -> String {
        var lines = text.components(separatedBy: "\n")
        lines = lines.filter { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("<video") && t.contains("</video>") { return false }
            if t.hasPrefix("<video") || t == "</video>" { return false }
            if t.hasPrefix("<img") { return false }
            if (t.hasSuffix(".mp4") || t.hasSuffix(".mov")) && t.hasPrefix("http") { return false }
            if t.range(of: #"!\[[^\]]*\]\([^)]+\.(?:mp4|mov)\)"#, options: .regularExpression) != nil { return false }
            if t.range(of: #"!\[[^\]]*\]\([^)]+\.(?:png|jpe?g|gif|webp)\)"#, options: .regularExpression) != nil { return false }
            if t.range(of: #"!\[[^\]]*\]\(https://[^)]*user-images[^)]+\)"#, options: .regularExpression) != nil { return false }
            return true
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Simple markdown to plain text (strip #, *, -, links)
    static func renderMarkdownPlain(_ text: String) -> String {
        var result = text
        // Strip heading markers ((?m) makes ^ match each line start)
        result = result.replacingOccurrences(of: #"(?m)^#{1,6}\s+"#, with: "", options: .regularExpression)
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
