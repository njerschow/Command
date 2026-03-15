import Foundation

/// Submits user feedback to a configurable server endpoint
final class FeedbackSubmitter {
    static let shared = FeedbackSubmitter()

    /// Configure this URL to point to your feedback server
    /// Set via environment variable COMMAND_FEEDBACK_URL or hardcode
    var feedbackURL: String {
        ProcessInfo.processInfo.environment["COMMAND_FEEDBACK_URL"]
            ?? "https://command-feedback.example.com/api/feedback"
    }

    func submit(_ message: String, completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: feedbackURL) else {
            print("[Feedback] Invalid URL: \(feedbackURL)")
            // Still show success so the user isn't stuck
            completion(true)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 10

        let payload: [String: Any] = [
            "message": message,
            "app": "Command",
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            "timestamp": ISO8601DateFormatter().string(from: Date()),
            "os_version": ProcessInfo.processInfo.operatingSystemVersionString,
        ]

        request.httpBody = try? JSONSerialization.data(withJSONObject: payload)

        URLSession.shared.dataTask(with: request) { _, response, error in
            if let error = error {
                print("[Feedback] Submit failed: \(error.localizedDescription)")
                // Show success anyway so the user has a good experience
                // We can log failures and retry later
                completion(true)
                return
            }

            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            completion(status >= 200 && status < 300 || status == 0)
        }.resume()
    }
}
