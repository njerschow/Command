import SwiftUI

struct StatusDotView: View {
    let status: TerminalStatus
    var claudeState: ClaudeState? = nil
    var sessionTag: String = "term"
    var isAutopilot: Bool = false
    var autopilotState: AutopilotManager.SessionState? = nil

    var body: some View {
        if isAutopilot {
            AutopilotPlaneView(state: autopilotState ?? .idle)
                .frame(width: 14, height: 14)
        } else if sessionTag == "openclaw" && status == .running {
            BrailleSpinnerView()
                .frame(width: 14, height: 14)
        } else if let claudeState, claudeState == .working {
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

    /// Only pulse for states that need urgent attention (permission)
    private var needsPulse: Bool {
        status == .actionRequired || claudeState == .needsPermission
    }

    var body: some View {
        ZStack {
            // Orange halo only for permission/action-required
            if needsPulse {
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
            case .working:
                return .green.opacity(0.8)         // sparkle handles this, but fallback
            case .waitingForUser:
                return .green.opacity(0.8)          // GREEN: done, ready for user
            case .needsPermission:
                return .orange                       // ORANGE: blocked, needs approval
            }
        }
        switch status {
        case .idle: return .secondary.opacity(0.4)   // gray
        case .running: return .green.opacity(0.8)    // green
        case .actionRequired: return .orange          // orange
        }
    }
}

// MARK: - OpenClaw Braille Spinner

struct BrailleSpinnerView: View {
    private static let frames: [String] = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]

    @State private var currentIndex = 0

    private let timer = Timer.publish(every: 0.1, on: .main, in: .common).autoconnect()

    var body: some View {
        Text(Self.frames[currentIndex])
            .font(.system(size: 12))
            .foregroundStyle(.green.opacity(0.8))
            .onReceive(timer) { _ in
                currentIndex = (currentIndex + 1) % Self.frames.count
            }
    }
}

// MARK: - Autopilot Plane (state-aware)

struct AutopilotPlaneView: View {
    let state: AutopilotManager.SessionState

    @State private var phase: CGFloat = 0
    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        ZStack {
            // Thinking: subtle glow ring
            if state == .thinking {
                Circle()
                    .fill(AutopilotStyle.color.opacity(0.15))
                    .frame(width: 14, height: 14)
                    .scaleEffect(pulseScale)
            }

            Image(systemName: planeIcon)
                .font(.system(size: planeSize))
                .foregroundStyle(planeColor)
                .rotationEffect(planeRotation)
                .offset(y: planeOffset)
        }
        .animation(
            .linear(duration: animationDuration).repeatForever(autoreverses: false),
            value: phase
        )
        .animation(
            .easeInOut(duration: 1.0).repeatForever(autoreverses: true),
            value: pulseScale
        )
        .onAppear {
            phase = 1
            if state == .thinking { pulseScale = 1.3 }
        }
        .onChange(of: state) { _, newState in
            if newState == .thinking { pulseScale = 1.3 }
            else { pulseScale = 1.0 }
        }
    }

    private var planeIcon: String {
        switch state {
        case .thinking: return "play.fill"
        case .injecting: return "play.fill"
        case .escalated: return "exclamationmark.triangle.fill"
        case .idle: return "play.fill"
        }
    }

    private var planeSize: CGFloat {
        if case .escalated = state { return 8 }
        return 9
    }

    private var planeColor: Color {
        switch state {
        case .thinking: return AutopilotStyle.activeColor
        case .injecting: return .green.opacity(0.8)
        case .escalated: return .orange.opacity(0.9)
        case .idle: return AutopilotStyle.color
        }
    }

    private var planeRotation: Angle {
        switch state {
        case .thinking:
            // Faster wobble while thinking
            return .degrees(Double(phase) * 12 - 6)
        case .injecting:
            // Tilted forward — sending
            return .degrees(15)
        case .escalated:
            return .degrees(0)
        case .idle:
            return .degrees(Double(phase) * 6 - 3)
        }
    }

    private var planeOffset: CGFloat {
        switch state {
        case .thinking:
            return sin(phase * .pi * 2) * 1.5
        case .injecting:
            // Quick upward motion
            return -phase * 2
        case .escalated:
            return 0
        case .idle:
            return sin(phase * .pi * 2) * 1.2
        }
    }

    private var animationDuration: TimeInterval {
        switch state {
        case .thinking: return 1.2   // faster wobble
        case .injecting: return 0.4  // quick send
        case .escalated: return 2.4
        case .idle: return 2.4
        }
    }
}

/// Shared autopilot styling constants
enum AutopilotStyle {
    static let color = Color(hue: 0.75, saturation: 0.7, brightness: 0.55)        // dark violet
    static let activeColor = Color(hue: 0.75, saturation: 0.65, brightness: 0.65) // medium violet for active
    static let dimColor = Color(hue: 0.75, saturation: 0.6, brightness: 0.5)      // muted dark violet
}

/// Replicates the Claude Code CLI sparkle: · ✢ ✳ ✶ ✻ ✽ with ping-pong
struct ClaudeSparkleView: View {
    private static let phases: [String] = ["·", "✢", "✳", "✶", "✻", "✽"]
    private static let cycle: [String] = phases + phases.dropFirst().dropLast().reversed()

    @State private var currentIndex = 0

    private let timer = Timer.publish(every: 0.22, on: .main, in: .common).autoconnect()

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
