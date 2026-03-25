import Foundation
import Combine

/// Coordinates scanning across all terminal adapters
final class TerminalScanner {
    private let terminalAdapter = TerminalAppAdapter()
    private let itermAdapter = ITermAdapter()
    private var timer: Timer?
    private let scanQueue = DispatchQueue(label: "com.command.scanner", qos: .userInitiated)
    private var isScanning = false

    /// Scan all terminal apps and return grouped results
    func scan() -> [TerminalGroup] {
        var groups: [TerminalGroup] = []

        // Terminal.app
        groups.append(contentsOf: terminalAdapter.scan())

        // iTerm2
        groups.append(contentsOf: itermAdapter.scan())

        // TODO: Kitty, Ghostty, Warp adapters

        return groups
    }

    /// Start periodic scanning
    func startPolling(interval: TimeInterval = 2.0, onUpdate: @escaping ([TerminalGroup]) -> Void) {
        stopPolling()

        // Scan immediately on background
        runScan(onUpdate: onUpdate)

        // Then poll on interval
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.runScan(onUpdate: onUpdate)
        }
    }

    private func runScan(onUpdate: @escaping ([TerminalGroup]) -> Void) {
        guard !isScanning else { return }
        isScanning = true
        scanQueue.async { [weak self] in
            guard let self else { return }
            let results = self.scan()
            DispatchQueue.main.async {
                self.isScanning = false
                onUpdate(results)
            }
        }
    }

    /// Stop periodic scanning
    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }
}
