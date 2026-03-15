import SwiftUI

struct StatusDotView: View {
    let status: TerminalStatus

    @State private var isPulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
            .scaleEffect(isPulsing && status == .actionRequired ? 1.3 : 1.0)
            .opacity(isPulsing && status == .actionRequired ? 0.7 : 1.0)
            .animation(
                status == .actionRequired
                    ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true)
                    : .default,
                value: isPulsing
            )
            .onAppear {
                if status == .actionRequired {
                    isPulsing = true
                }
            }
            .onChange(of: status) { _, newStatus in
                isPulsing = newStatus == .actionRequired
            }
    }

    private var color: Color {
        switch status {
        case .idle: return .secondary.opacity(0.5)
        case .running: return .blue.opacity(0.8)
        case .actionRequired: return .green
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        StatusDotView(status: .idle)
        StatusDotView(status: .running)
        StatusDotView(status: .actionRequired)
    }
    .padding()
}
