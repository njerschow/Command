import SwiftUI

struct StatusDotView: View {
    let status: TerminalStatus
    var claudeState: ClaudeState? = nil

    var body: some View {
        if let claudeState, claudeState == .working {
            ClaudeSparkleView()
                .frame(width: 14, height: 14)
        } else {
            StaticDotView(status: status, claudeState: claudeState)
        }
    }
}

// MARK: - Static Dot (non-sparkle states)

private struct StaticDotView: View {
    let status: TerminalStatus
    let claudeState: ClaudeState?

    @State private var isPulsing = false

    private var needsPulse: Bool {
        status == .actionRequired || claudeState == .waitingForUser || claudeState == .needsPermission
    }

    var body: some View {
        ZStack {
            if status == .actionRequired || claudeState == .needsPermission {
                Circle()
                    .fill(Color.orange.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isPulsing ? 1.4 : 0.8)
                    .opacity(isPulsing ? 0 : 0.6)
            }

            Circle()
                .fill(dotColor)
                .frame(width: 9, height: 9)
                .scaleEffect(isPulsing && needsPulse ? 1.15 : 1.0)
        }
        .frame(width: 14, height: 14)
        .animation(
            needsPulse
                ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                : .default,
            value: isPulsing
        )
        .onAppear {
            if needsPulse { isPulsing = true }
        }
        .onChange(of: status) { _, _ in
            withAnimation { isPulsing = needsPulse }
        }
        .onChange(of: claudeState) { _, _ in
            withAnimation { isPulsing = needsPulse }
        }
    }

    private var dotColor: Color {
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
        let pos = Double(currentIndex) / Double(Self.cycle.count - 1)
        let wave = sin(pos * .pi)
        return 0.4 + wave * 0.6
    }
}
