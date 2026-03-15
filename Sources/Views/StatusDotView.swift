import SwiftUI

struct StatusDotView: View {
    let status: TerminalStatus
    var claudeState: ClaudeState? = nil

    @State private var isPulsing = false

    var body: some View {
        if let claudeState, claudeState == .working {
            ClaudeSparkleView()
                .frame(width: 14, height: 14)
        } else {
            ZStack {
                // Outer glow for action required
                if status == .actionRequired || claudeState == .needsPermission {
                    Circle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: 16, height: 16)
                        .scaleEffect(isPulsing ? 1.4 : 0.8)
                        .opacity(isPulsing ? 0 : 0.6)
                }

                // Main dot
                Circle()
                    .fill(dotColor)
                    .frame(width: 9, height: 9)
                    .scaleEffect(isPulsing && (status == .actionRequired || claudeState == .waitingForUser || claudeState == .needsPermission) ? 1.15 : 1.0)
            }
            .frame(width: 14, height: 14)
            .animation(
                (status == .actionRequired || claudeState == .waitingForUser || claudeState == .needsPermission)
                    ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if status == .actionRequired || claudeState == .waitingForUser || claudeState == .needsPermission {
                    isPulsing = true
                }
            }
            .onChange(of: status) { _, newStatus in
                withAnimation {
                    isPulsing = newStatus == .actionRequired || claudeState == .waitingForUser || claudeState == .needsPermission
                }
            }
        }
    }

    private var dotColor: Color {
        // Claude states override
        if let claudeState {
            switch claudeState {
            case .working: return .green.opacity(0.8)
            case .waitingForUser: return .yellow.opacity(0.9)
            case .needsPermission: return .orange
            }
        }
        switch status {
        case .idle: return .secondary.opacity(0.4)
        case .running: return .green.opacity(0.8)
        case .actionRequired: return .orange
        }
    }
}

// MARK: - Claude Sparkle Animation

/// Replicates the Claude Code CLI sparkle: · ✢ ✳ ✶ ✻ ✽ with ping-pong
struct ClaudeSparkleView: View {
    private static let phases: [String] = ["·", "✢", "✳", "✶", "✻", "✽"]
    // Full ping-pong cycle: forward then reverse (minus endpoints to avoid doubling)
    private static let cycle: [String] = phases + phases.dropFirst().dropLast().reversed()

    @State private var currentIndex = 0

    private let timer = Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(Self.cycle[currentIndex])
            .font(.system(size: 12))
            .foregroundStyle(.primary.opacity(opacity))
            .onReceive(timer) { _ in
                currentIndex = (currentIndex + 1) % Self.cycle.count
            }
    }

    private var opacity: Double {
        // Map position in cycle to opacity: dim at start, bright at peak
        let pos = Double(currentIndex) / Double(Self.cycle.count - 1)
        let wave = sin(pos * .pi) // 0 → 1 → 0
        return 0.4 + wave * 0.6
    }
}
