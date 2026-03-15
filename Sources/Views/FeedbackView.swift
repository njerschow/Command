import SwiftUI

struct FeedbackView: View {
    @State private var isExpanded = false
    @State private var feedbackText = ""
    @State private var showSuccess = false
    @State private var isSubmitting = false
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            if showSuccess {
                successView
            } else if isExpanded {
                expandedView
            } else {
                collapsedView
            }
        }
        .animation(.spring(duration: 0.35, bounce: 0.15), value: isExpanded)
        .animation(.spring(duration: 0.3, bounce: 0.1), value: showSuccess)
    }

    // MARK: - Collapsed

    private var collapsedView: some View {
        Button(action: { expand() }) {
            HStack(spacing: 4) {
                Image(systemName: "bubble.left")
                    .font(.system(size: 10))
                Text("Give feedback")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .onHover { inside in
            if inside { NSCursor.pointingHand.push() }
            else { NSCursor.pop() }
        }
    }

    // MARK: - Expanded

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 6) {
            feedbackInputRow
            feedbackHintRow
        }
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomLeading)))
    }

    private var feedbackInputRow: some View {
        HStack(spacing: 6) {
            TextField("What can we improve?", text: $feedbackText, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .lineLimit(1...3)
                .focused($isFocused)

            submitButton
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(feedbackInputBackground)
    }

    @ViewBuilder
    private var submitButton: some View {
        if isSubmitting {
            ProgressView()
                .scaleEffect(0.5)
                .frame(width: 16, height: 16)
        } else {
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 16))
                    .foregroundColor(feedbackText.isEmpty ? .secondary : .blue)
            }
            .buttonStyle(.plain)
            .disabled(feedbackText.isEmpty)
        }
    }

    private var feedbackInputBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color.primary.opacity(0.04))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
            )
    }

    private var feedbackHintRow: some View {
        HStack {
            Text("⌘↵ to send")
                .font(.system(size: 10))
                .foregroundStyle(.quaternary)
            Spacer()
            Button("Cancel") { collapse() }
                .font(.system(size: 10))
                .buttonStyle(.plain)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Success

    private var successView: some View {
        HStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: showSuccess)
            Text("Thanks for the feedback!")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .transition(.opacity.combined(with: .scale(scale: 0.9)))
    }

    // MARK: - Actions

    private func expand() {
        isExpanded = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isFocused = true
        }
    }

    private func collapse() {
        isFocused = false
        withAnimation {
            isExpanded = false
            feedbackText = ""
        }
    }

    private func submit() {
        let trimmed = feedbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        isSubmitting = true

        FeedbackSubmitter.shared.submit(trimmed) { success in
            DispatchQueue.main.async {
                isSubmitting = false
                if success {
                    feedbackText = ""
                    isExpanded = false
                    showSuccess = true

                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                        withAnimation { showSuccess = false }
                    }
                }
            }
        }
    }
}
