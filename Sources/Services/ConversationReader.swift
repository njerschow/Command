import Foundation

/// Reads Claude Code JSONL session files and extracts conversation history for the autopilot brain
enum ConversationReader {

    struct Turn {
        let role: String        // "user" or "assistant"
        let text: String
        let toolCalls: [String]
    }

    /// Read the last N conversation turns from a session's JSONL file
    static func readHistory(sessionID: String, cwd: String, maxTurns: Int = 20) -> [Turn] {
        guard let path = findJSONLPath(sessionID: sessionID, cwd: cwd) else { return [] }
        guard let data = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }

        var turns: [Turn] = []
        for line in data.components(separatedBy: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  (type == "user" || type == "assistant"),
                  let message = obj["message"] as? [String: Any] else { continue }

            let role = message["role"] as? String ?? type
            var text = ""
            var toolCalls: [String] = []

            if let content = message["content"] as? String {
                text = content
            } else if let content = message["content"] as? [[String: Any]] {
                for block in content {
                    let blockType = block["type"] as? String
                    if blockType == "text" {
                        text += (block["text"] as? String ?? "")
                    } else if blockType == "tool_use" {
                        toolCalls.append(block["name"] as? String ?? "unknown")
                    }
                }
            }

            if text.isEmpty && toolCalls.isEmpty { continue }

            turns.append(Turn(role: role, text: text, toolCalls: toolCalls))
        }

        return Array(turns.suffix(maxTurns))
    }

    /// Format turns into a readable prompt for the autopilot brain
    static func formatForPrompt(_ turns: [Turn], maxChars: Int = 12000) -> String {
        var result = ""
        for turn in turns {
            let prefix = turn.role == "user" ? "Human" : "Claude"
            var entry = "\(prefix): "
            if !turn.text.isEmpty {
                let truncated = turn.text.count > 800
                    ? String(turn.text.prefix(800)) + "...[truncated]"
                    : turn.text
                entry += truncated
            }
            if !turn.toolCalls.isEmpty {
                entry += " [Tools: \(turn.toolCalls.joined(separator: ", "))]"
            }
            result += entry + "\n\n"
        }

        if result.count > maxChars {
            result = "...(earlier turns truncated)...\n\n" + String(result.suffix(maxChars - 40))
        }
        return result
    }

    // MARK: - File Discovery

    /// Find the JSONL file path for a session, trying direct path first then scanning
    private static func findJSONLPath(sessionID: String, cwd: String) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let encodedPath = cwd.replacingOccurrences(of: "/", with: "-")
        let directPath = "\(home)/.claude/projects/\(encodedPath)/\(sessionID).jsonl"

        if FileManager.default.fileExists(atPath: directPath) {
            return directPath
        }

        // Scan all project directories for the session file
        let projectsDir = "\(home)/.claude/projects"
        guard let dirs = try? FileManager.default.contentsOfDirectory(atPath: projectsDir) else { return nil }
        for dir in dirs {
            let candidate = "\(projectsDir)/\(dir)/\(sessionID).jsonl"
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
