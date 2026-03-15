import Foundation
import CryptoKit

/// Normalizes terminal output for stable fingerprinting
enum ContentNormalizer {

    /// Compute a short hex fingerprint of normalized text
    static func fingerprint(_ text: String) -> String {
        let normalized = normalize(text)
        let hash = SHA256.hash(data: Data(normalized.utf8))
        return hash.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// Strip ANSI, spinners, progress bars, timestamps for stable comparison
    static func normalize(_ text: String) -> String {
        var s = text

        // ANSI escape sequences (CSI + OSC)
        s = s.replacingOccurrences(
            of: "\u{001B}\\[[0-9;]*[A-Za-z]|\u{001B}\\][^\u{0007}]*\u{0007}",
            with: "", options: .regularExpression
        )

        // Braille spinner characters U+2800-U+28FF (Claude Code, OpenClaw)
        s = s.replacingOccurrences(
            of: "[\\u{2800}-\\u{28FF}]",
            with: "", options: .regularExpression
        )

        // Progress bars: [=====>   ] [######   ] and percentages
        s = s.replacingOccurrences(
            of: "\\[[-=#>\\s]+\\]|\\d{1,3}%",
            with: "", options: .regularExpression
        )

        // Timing: (0.5s) (12.3s) 00:01:23
        s = s.replacingOccurrences(
            of: "\\(\\d+\\.?\\d*s\\)|\\d{2}:\\d{2}:\\d{2}",
            with: "", options: .regularExpression
        )

        // Normalize lines
        return s.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    /// Extract the last N lines from text
    static func lastLines(_ text: String, count: Int) -> String {
        let lines = text.components(separatedBy: "\n")
        return Array(lines.suffix(count)).joined(separator: "\n")
    }
}
