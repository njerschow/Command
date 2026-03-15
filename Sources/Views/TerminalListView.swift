import SwiftUI

struct TerminalListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var summaryManager: SummaryManager
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var hookServer: ClaudeHookServer
    @State private var selectedIndex: Int? = nil
    @State private var savedExpanded = true

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
        if appState.terminalGroups.isEmpty && sessionStore.recentlyClosed.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(appState.sortedGroups) { group in
                        terminalGroupView(group)
                    }

                    if !sessionStore.recentlyClosed.isEmpty {
                        recentlyClosedSection
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
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
            group: group,
            summary: summaryManager.summary(for: tab.id),
            lastActive: effectiveLastActive(tab.id),
            context: summaryManager.context(for: tab.id),
            shortcutIndex: globalIdx,
            isSelected: selectedIndex == globalIdx,
            claudeState: claudeState(for: tab),
            onSelect: { focusTerminal(group: group, tab: tab) },
            onSaveAndClose: {
                sessionStore.saveAndClose(group: group, tab: tab, summary: summaryManager.summary(for: tab.id),
                                         contentReader: summaryManager.contentReader, hookServer: hookServer)
            }
        )
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
                    group: group,
                    summary: summaryManager.summary(for: tab.id),
                    lastActive: effectiveLastActive(tab.id),
                    context: summaryManager.context(for: tab.id),
                    shortcutIndex: startIndex + index,
                    isSelected: selectedIndex == startIndex + index,
                    claudeState: claudeState(for: tab),
                    onSelect: { focusTerminal(group: group, tab: tab) },
                    onSaveAndClose: {
                        sessionStore.saveAndClose(group: group, tab: tab, summary: summaryManager.summary(for: tab.id),
                                         contentReader: summaryManager.contentReader, hookServer: hookServer)
                    }
                )
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

    // MARK: - Saved Sessions

    private var recentlyClosedSection: some View {
        VStack(alignment: .leading, spacing: 1) {
            // Collapsible header
            Button(action: {
                withAnimation(.easeOut(duration: 0.15)) { savedExpanded.toggle() }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: savedExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .frame(width: 10)

                    Text("Saved")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)

                    Text("\(sessionStore.recentlyClosed.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)

                    Spacer()

                    if savedExpanded {
                        Button("Clear") {
                            withAnimation { sessionStore.clearAll() }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .buttonStyle(.plain)
                    }
                }
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 14)
            .padding(.top, 10)
            .padding(.bottom, 4)

            if savedExpanded {
                ForEach(sessionStore.recentlyClosed) { session in
                    ClosedSessionRow(
                        session: session,
                        isActive: isSessionActive(session)
                    ) {
                        sessionStore.restore(session)
                    } onDismiss: {
                        withAnimation { sessionStore.dismiss(session) }
                    }
                }
            }
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

    // MARK: - Helpers

    /// Check if a saved session has been restored (matching cwd in active tabs)
    private func isSessionActive(_ session: SavedSession) -> Bool {
        // Immediately active if user clicked Restore
        if sessionStore.restoredSessionIDs.contains(session.id) {
            return true
        }
        guard let dir = session.workingDirectory else { return false }
        // Check cached directories
        for group in appState.terminalGroups {
            for tab in group.tabs {
                if sessionStore.cachedDirectory(for: tab.id) == dir {
                    return true
                }
            }
        }
        return false
    }

    /// Look up Claude hook state for a tab by matching its cached cwd
    private func claudeState(for tab: TerminalTab) -> ClaudeState? {
        guard tab.isClaudeSession,
              let cwd = sessionStore.cachedDirectory(for: tab.id),
              let session = hookServer.session(forCwd: cwd) else { return nil }
        return session.state
    }

    // MARK: - Actions

    private func focusTerminal(group: TerminalGroup, tab: TerminalTab) {
        WindowFocuser.shared.focus(group: group, tab: tab)
    }
}

// MARK: - Closed Session Row

struct ClosedSessionRow: View {
    let session: SavedSession
    let isActive: Bool
    let onRestore: () -> Void
    let onDismiss: () -> Void

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 8) {
            // Green dot for active (restored), gray for closed
            Circle()
                .fill(isActive ? Color.green.opacity(0.8) : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.summary)
                        .font(.system(size: 13))
                        .foregroundStyle(isActive ? .tertiary : .secondary)
                        .lineLimit(1)

                    if session.wasClaudeSession {
                        Text("claude")
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 3)
                            .padding(.vertical, 1)
                            .background(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(Color.primary.opacity(0.04))
                            )
                    }
                }

                if let dir = session.workingDirectory {
                    Text(dir.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isHovered {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)

                if !isActive {
                    Button(action: onRestore) {
                        Image(systemName: "arrow.uturn.left")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .transition(.opacity)
                }
            } else {
                Text(relativeTime(session.closedAt))
                    .font(.system(size: 11, design: .rounded))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.leading, 6)
        .padding(.trailing, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovered ? Color.primary.opacity(0.04) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            if !isActive { onRestore() }
        }
        .onHover { hovering in
            withAnimation(.easeOut(duration: 0.12)) { isHovered = hovering }
        }
        .padding(.horizontal, 2)
    }

    private func relativeTime(_ date: Date) -> String {
        let seconds = -date.timeIntervalSinceNow
        if seconds < 60 { return "now" }
        if seconds < 3600 {
            let m = Int(seconds / 60)
            return "\(m)m ago"
        }
        if seconds < 86400 {
            let h = Int(seconds / 3600)
            return "\(h)h ago"
        }
        if seconds < 604800 {
            let d = Int(seconds / 86400)
            return "\(d)d ago"
        }
        let w = Int(seconds / 604800)
        return "\(w)w ago"
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
