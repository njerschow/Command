import SwiftUI

/// Tiny icon showing where a terminal window sits on screen
struct WindowPositionView: View {
    let frame: WindowFrame

    // Icon dimensions
    private let iconWidth: CGFloat = 18
    private let iconHeight: CGFloat = 12
    private let cornerRadius: CGFloat = 2
    private let innerCornerRadius: CGFloat = 1

    var body: some View {
        Canvas { context, size in
            // Outer rounded rect = screen
            let outer = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .path(in: CGRect(origin: .zero, size: size).insetBy(dx: 0.5, dy: 0.5))
            context.stroke(outer, with: .color(.primary.opacity(0.35)), lineWidth: 0.75)

            // Inner rounded rect = window position
            let screen = screenSize
            guard screen.width > 0, screen.height > 0 else { return }

            let scaleX = (size.width - 3) / screen.width
            let scaleY = (size.height - 3) / screen.height

            let x = 1.5 + CGFloat(frame.x) * scaleX
            let y = 1.5 + CGFloat(frame.y) * scaleY
            let w = max(3, CGFloat(frame.width) * scaleX)
            let h = max(2, CGFloat(frame.height) * scaleY)

            let innerRect = CGRect(x: x, y: y, width: w, height: h)
                .intersection(CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1))

            let inner = RoundedRectangle(cornerRadius: innerCornerRadius, style: .continuous)
                .path(in: innerRect)
            context.fill(inner, with: .color(.primary.opacity(0.45)))
        }
        .frame(width: iconWidth, height: iconHeight)
    }

    private var screenSize: (width: CGFloat, height: CGFloat) {
        if let screen = NSScreen.main {
            let f = screen.frame
            return (f.width, f.height)
        }
        return (1920, 1080)
    }
}
