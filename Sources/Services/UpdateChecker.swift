import Foundation

/// Checks GitHub releases for newer versions of the app
final class UpdateChecker: ObservableObject {
    @Published var latestVersion: String?
    @Published var updateAvailable = false
    @Published var releaseURL: String?
    @Published var releaseNotes: String?
    @Published var releaseVideoURL: String?
    @Published var releaseImageURL: String?
    @Published var downloadURL: String?

    private let repo: String
    let currentVersion: String
    private var lastCheckTime: Date = .distantPast
    private let checkInterval: TimeInterval = 3600 // 1 hour between checks

    init(repo: String = "njerschow/Command") {
        self.repo = repo
        self.currentVersion = Self.readCurrentVersion()
    }

    /// Read version from bundle Info.plist
    private static func readCurrentVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// Check GitHub API for latest release (rate-limited to once per hour)
    func checkForUpdates(force: Bool = false) {
        guard force || Date().timeIntervalSince(lastCheckTime) > checkInterval else { return }
        lastCheckTime = Date()

        let urlString = "https://api.github.com/repos/\(repo)/releases/latest"
        guard let url = URL(string: urlString) else { return }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 10

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self,
                  let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tagName = json["tag_name"] as? String,
                  let htmlURL = json["html_url"] as? String else {
                return
            }

            let remoteVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "v"))
            let isNewer = Self.compareVersions(remote: remoteVersion, local: self.currentVersion)
            let body = json["body"] as? String
            let videoURL = body.flatMap { Self.extractVideoURL(from: $0) }
            let imageURL = body.flatMap { Self.extractImageURL(from: $0) }

            // Find .zip asset download URL
            let assets = json["assets"] as? [[String: Any]] ?? []
            let zipAsset = assets.first { ($0["name"] as? String)?.hasSuffix(".zip") == true }
            let zipURL = zipAsset?["browser_download_url"] as? String

            DispatchQueue.main.async {
                self.latestVersion = remoteVersion
                self.releaseURL = htmlURL
                self.updateAvailable = isNewer
                self.releaseNotes = body
                self.releaseVideoURL = videoURL
                self.releaseImageURL = imageURL
                self.downloadURL = zipURL
            }
        }.resume()
    }

    /// Extract first video URL from markdown release notes
    /// Looks for: ![video](url), <video src="url">, or raw .mp4/.mov URLs
    static func extractVideoURL(from markdown: String) -> String? {
        // <video src="..."> or <video ... src="...">
        if let range = markdown.range(of: #"<video[^>]*\ssrc="([^"]+)"#, options: .regularExpression) {
            let match = String(markdown[range])
            if let srcRange = match.range(of: #"src="([^"]+)"#, options: .regularExpression) {
                let src = String(match[srcRange]).replacingOccurrences(of: "src=\"", with: "").replacingOccurrences(of: "\"", with: "")
                return src
            }
        }
        // Raw .mp4/.mov URL on its own line
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if (trimmed.hasSuffix(".mp4") || trimmed.hasSuffix(".mov")),
               trimmed.hasPrefix("http") {
                return trimmed
            }
        }
        // ![...](url.mp4) or ![...](url.mov)
        if let range = markdown.range(of: #"!\[[^\]]*\]\(([^)]+\.(?:mp4|mov))\)"#, options: .regularExpression) {
            let match = String(markdown[range])
            if let urlStart = match.firstIndex(of: "("), let urlEnd = match.lastIndex(of: ")") {
                let url = String(match[match.index(after: urlStart)..<urlEnd])
                return url
            }
        }
        return nil
    }

    /// Extract first image URL from markdown release notes
    static func extractImageURL(from markdown: String) -> String? {
        // ![alt](url.png/jpg/gif/webp)
        if let range = markdown.range(of: #"!\[[^\]]*\]\(([^)]+\.(?:png|jpe?g|gif|webp))\)"#, options: .regularExpression) {
            let match = String(markdown[range])
            if let urlStart = match.firstIndex(of: "("), let urlEnd = match.lastIndex(of: ")") {
                return String(match[match.index(after: urlStart)..<urlEnd])
            }
        }
        // GitHub user-content image URLs (uploaded via drag-and-drop)
        if let range = markdown.range(of: #"!\[[^\]]*\]\((https://[^)]*user-images[^)]+)\)"#, options: .regularExpression) {
            let match = String(markdown[range])
            if let urlStart = match.firstIndex(of: "("), let urlEnd = match.lastIndex(of: ")") {
                return String(match[match.index(after: urlStart)..<urlEnd])
            }
        }
        // <img src="...">
        if let range = markdown.range(of: #"<img[^>]*\ssrc="([^"]+)"#, options: .regularExpression) {
            let match = String(markdown[range])
            if let srcRange = match.range(of: #"src="([^"]+)"#, options: .regularExpression) {
                return String(match[srcRange]).replacingOccurrences(of: "src=\"", with: "").replacingOccurrences(of: "\"", with: "")
            }
        }
        return nil
    }

    /// Semantic version comparison: returns true if remote > local
    static func compareVersions(remote: String, local: String) -> Bool {
        let r = remote.split(separator: ".").compactMap { Int($0) }
        let l = local.split(separator: ".").compactMap { Int($0) }
        let count = max(r.count, l.count)
        for i in 0..<count {
            let rv = i < r.count ? r[i] : 0
            let lv = i < l.count ? l[i] : 0
            if rv > lv { return true }
            if rv < lv { return false }
        }
        return false
    }
}
