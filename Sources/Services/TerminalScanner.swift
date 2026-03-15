import Foundation
import Combine

/// Coordinates scanning across all terminal adapters
final class TerminalScanner {
    private let terminalAdapter = TerminalAppAdapter()
    private var timer: Timer?
    private var isPopoverVisible = false

    /// Scan all terminal apps and return grouped results
    func scan() -> [TerminalGroup] {
        var groups: [TerminalGroup] = []

        // Terminal.app
        groups.append(contentsOf: terminalAdapter.scan())

        // TODO: iTerm2, Kitty, Ghostty, Warp adapters

        return groups
    }

    /// Start periodic scanning
    func startPolling(interval: TimeInterval = 2.0, onUpdate: @escaping ([TerminalGroup]) -> Void) {
        stopPolling()

        // Scan immediately
        let results = scan()
        onUpdate(results)

        // Then poll on interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self else { return }
            let results = self.scan()
            DispatchQueue.main.async {
                onUpdate(results)
            }
        }
    }

    /// Stop periodic scanning
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    /// Adjust polling rate based on visibility
    func setPopoverVisible(_ visible: Bool) {
        isPopoverVisible = visible
        // Could adjust polling rate here in the future
    }
}
