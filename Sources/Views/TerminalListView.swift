import SwiftUI

struct TerminalListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var summaryManager: SummaryManager
    @State private var selectedIndex: Int? = nil

    var body: some View {
        VStack(spacing: 0) {
            terminalList

            Divider()
                .padding(.horizontal, 8)

            footer
        }
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
        .background(keyboardHandler)
    }

    // MARK: - Keyboard Handler

    private var keyboardHandler: some View {
        KeyboardHandlerView { event in
            handleKeyEvent(event)
        }
        .frame(width: 0, height: 0)
    }

    private func handleKeyEvent(_ event: NSEvent) {
        let totalTabs = appState.allTabs.count

        // ⌘+1-9: quick switch
        if event.modifierFlags.contains(.command),
           let chars = event.charactersIgnoringModifiers,
           let digit = Int(chars), digit >= 1, digit <= 9 {
            let index = digit - 1
            if let (group, tab) = appState.tab(at: index) {
                focusTerminal(group: group, tab: tab)
            }
            return
        }

        switch event.keyCode {
        case 125: // Down arrow
            if let current = selectedIndex {
                selectedIndex = min(current + 1, totalTabs - 1)
            } else {
                selectedIndex = 0
            }
        case 126: // Up arrow
            if let current = selectedIndex {
                selectedIndex = max(current - 1, 0)
            } else {
                selectedIndex = totalTabs - 1
            }
        case 36: // Return/Enter
            if let index = selectedIndex,
               let (group, tab) = appState.tab(at: index) {
                focusTerminal(group: group, tab: tab)
            }
        default:
            break
        }
    }

    // MARK: - Terminal List

    @ViewBuilder
    private var terminalList: some View {
        if appState.terminalGroups.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(appState.sortedGroups) { group in
                        terminalGroupView(group)
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 4)
            }
            .frame(maxHeight: 420)
        }
    }

    // MARK: - Group

    @ViewBuilder
    private func terminalGroupView(_ group: TerminalGroup) -> some View {
        if group.tabs.count == 1, let tab = group.tabs.first {
            singleTabRow(group: group, tab: tab)
        } else {
            multiTabSection(group: group)
        }
    }

    private func singleTabRow(group: TerminalGroup, tab: TerminalTab) -> some View {
        let globalIdx = appState.globalIndex(for: group)
        return TerminalRowView(
            tab: tab,
            summary: summaryManager.summary(for: tab.id),
            lastActive: effectiveLastActive(tab.id),
            context: summaryManager.context(for: tab.id),
            shortcutIndex: globalIdx,
            isSelected: selectedIndex == globalIdx
        ) {
            focusTerminal(group: group, tab: tab)
        }
    }

    private func multiTabSection(group: TerminalGroup) -> some View {
        let startIndex = appState.globalIndex(for: group)
        return VStack(alignment: .leading, spacing: 1) {
            // Section header
            HStack(spacing: 4) {
                if let icon = group.app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 12, height: 12)
                }
                Text(group.displayName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)

                if group.tabs.count > 1 {
                    Text("· \(group.tabs.count) tabs")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 6)
            .padding(.bottom, 2)

            ForEach(Array(group.tabs.enumerated()), id: \.element.id) { index, tab in
                TerminalRowView(
                    tab: tab,
                    summary: summaryManager.summary(for: tab.id),
                    lastActive: effectiveLastActive(tab.id),
                    context: summaryManager.context(for: tab.id),
                    shortcutIndex: startIndex + index,
                    isSelected: selectedIndex == startIndex + index
                ) {
                    focusTerminal(group: group, tab: tab)
                }
            }
        }
    }

    /// Merge scan-based and content-based activity times
    private func effectiveLastActive(_ tabID: String) -> Date? {
        let scan = appState.lastActivity[tabID]
        let content = summaryManager.lastActivity(for: tabID)
        switch (scan, content) {
        case (.some(let a), .some(let b)): return max(a, b)
        case (.some(let a), nil): return a
        case (nil, .some(let b)): return b
        case (nil, nil): return nil
        }
    }

    // MARK: - Empty State

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("No terminals open")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .frame(height: 120)
        .frame(maxWidth: .infinity)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            FeedbackView()

            Spacer()

            Text("⌘.")
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Actions

    private func focusTerminal(group: TerminalGroup, tab: TerminalTab) {
        WindowFocuser.shared.focus(group: group, tab: tab)
    }
}

// MARK: - Keyboard Handler NSView

/// Bridges NSView key events into SwiftUI
struct KeyboardHandlerView: NSViewRepresentable {
    let onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> KeyCaptureView {
        let view = KeyCaptureView()
        view.onKeyDown = onKeyDown
        return view
    }

    func updateNSView(_ nsView: KeyCaptureView, context: Context) {
        nsView.onKeyDown = onKeyDown
    }

    class KeyCaptureView: NSView {
        var onKeyDown: ((NSEvent) -> Void)?

        override var acceptsFirstResponder: Bool { true }

        override func keyDown(with event: NSEvent) {
            onKeyDown?(event)
        }
    }
}
