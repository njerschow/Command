import SwiftUI

struct StatusDotView: View {
    let status: TerminalStatus

    @State private var isPulsing = false

    var body: some View {
        ZStack {
            // Outer glow for action required
            if status == .actionRequired {
                Circle()
                    .fill(Color.orange.opacity(0.3))
                    .frame(width: 16, height: 16)
                    .scaleEffect(isPulsing ? 1.4 : 0.8)
                    .opacity(isPulsing ? 0 : 0.6)
            }

            // Main dot
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .scaleEffect(isPulsing && status == .actionRequired ? 1.15 : 1.0)
        }
        .frame(width: 14, height: 14)
        .animation(
            status == .actionRequired
                ? .easeInOut(duration: 1.5).repeatForever(autoreverses: true)
                : .default,
            value: isPulsing
        )
        .onAppear {
            if status == .actionRequired {
                isPulsing = true
            }
        }
        .onChange(of: status) { _, newStatus in
            withAnimation {
                isPulsing = newStatus == .actionRequired
            }
        }
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary.opacity(0.4)
        case .running: return .green.opacity(0.8)
        case .actionRequired: return .orange
        }
    }
}
