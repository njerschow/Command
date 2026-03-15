import SwiftUI

struct FeedbackView: View {
    var body: some View {
        Button(action: {
            if let url = URL(string: "https://github.com/njerschow/Command/issues") {
                NSWorkspace.shared.open(url)
            }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                Text("Feedback")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
        .help("Open GitHub Issues")
    }
}
