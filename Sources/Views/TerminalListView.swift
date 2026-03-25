import SwiftUI

struct TerminalListView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var summaryManager: SummaryManager
    @EnvironmentObject var sessionStore: SessionStore
    @EnvironmentObject var hookServer: ClaudeHookServer
    @EnvironmentObject var updateChecker: UpdateChecker
    @EnvironmentObject var autopilotManager: AutopilotManager
    @State private var selectedIndex: Int? = nil
    @State private var savedExpanded = true
    @State private var showHistory = false
    @State private var showUpdatePopover = false

    var body: some View {
        VStack(spacing: 0) {
            terminalList

            Divider()
                .padding(.horizontal, 8)

            footer
        }
        .frame(width: 400)
        .fixedSize(horizontal: true, vertical: true)
        .background(keyboardHandler)
        .onChange(of: appState.allTabs.count) { _, _ in
            selectedIndex = nil
        }
        .popover(isPresented: $showHistory, arrowEdge: .bottom) {
            SessionHistoryView(
                sessions: sessionStore.closedHistory,
                onRestore: { session in
                    restoreOrFocus(session)
                    showHistory = false
                },
                onSave: { session in
                    withAnimation { sessionStore.promoteToSaved(session) }
                },
                onDismiss: { session in
                    withAnimation { sessionStore.dismissHistory(session) }
                },
                onClearAll: {
                    sessionStore.clearHistory()
                    showHistory = false
                }
            )
        }
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
        if activeGroups.isEmpty && sessionStore.savedSessions.isEmpty {
            emptyState
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 2) {
                    ForEach(activeGroups) { group in
                        terminalGroupView(group)
                    }

                    if !sessionStore.savedSessions.isEmpty {
                        savedSessionsSection
                    }
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 2)
            }
            .frame(maxHeight: 420)
        }
    }

    /// Active groups with saved tabs filtered out
    private var activeGroups: [TerminalGroup] {
        let saved = sessionStore.savedTabIDs
        if saved.isEmpty { return appState.sortedGroups }
        return appState.sortedGroups.compactMap { group in
            let filtered = group.tabs.filter { !saved.contains($0.id) }
            if filtered.isEmpty { return nil }
            if filtered.count == group.tabs.count { return group }
            return TerminalGroup(id: group.id, app: group.app, windowTitle: group.windowTitle, windowID: group.windowID, tabs: filtered)
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
        let cwd = sessionStore.cachedDirectory(for: tab.id)
        let cachedSID = sessionStore.cachedClaudeSessionID(for: tab.id)
        let effectiveSID = cachedSID ?? cwd.flatMap { hookServer.sessionID(forCwd: $0) }
        return TerminalRowView(
            tab: tab,
            group: group,
            summary: summaryManager.summary(for: tab.id),
            lastActive: effectiveLastActive(tab.id),
            context: summaryManager.context(for: tab.id),
            shortcutIndex: globalIdx,
            isSelected: selectedIndex == globalIdx,
            claudeState: claudeState(for: tab),
            workingDirectory: cwd,
            claudeSessionID: effectiveSID,
            onSelect: { focusTerminal(group: group, tab: tab) },
            onSave: {
                sessionStore.saveSession(group: group, tab: tab, summary: summaryManager.summary(for: tab.id),
                                         contentReader: summaryManager.contentReader, hookServer: hookServer)
            },
            onClose: { closeTerminal(group: group, tab: tab) },
            windowFrame: sessionStore.cachedFrame(for: tab.id),
            isAutopilotEnabled: autopilotManager.isEnabled(tabID: tab.id),
            autopilotState: autopilotManager.sessionState(tabID: tab.id),
            autopilotCycleCount: autopilotManager.sessions[tab.id]?.cycleCount ?? 0,
            onToggleAutopilot: {
                guard let sid = effectiveSID else { return }
                if autopilotManager.isEnabled(tabID: tab.id) {
                    autopilotManager.disable(tabID: tab.id)
                } else {
                    autopilotManager.enable(tabID: tab.id, claudeSessionID: sid, group: group, tab: tab)
                }
            },
            onDismissEscalation: {
                autopilotManager.dismissEscalation(tabID: tab.id)
            },
            onTestInject: {
                WindowFocuser.shared.injectText("# test_inject_\(Int(Date().timeIntervalSince1970))", group: group, tab: tab)
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
                let cwd = sessionStore.cachedDirectory(for: tab.id)
                let cachedSID = sessionStore.cachedClaudeSessionID(for: tab.id)
                let effectiveSID = cachedSID ?? cwd.flatMap { hookServer.sessionID(forCwd: $0) }
                TerminalRowView(
                    tab: tab,
                    group: group,
                    summary: summaryManager.summary(for: tab.id),
                    lastActive: effectiveLastActive(tab.id),
                    context: summaryManager.context(for: tab.id),
                    shortcutIndex: startIndex + index,
                    isSelected: selectedIndex == startIndex + index,
                    claudeState: claudeState(for: tab),
                    workingDirectory: cwd,
                    claudeSessionID: effectiveSID,
                    onSelect: { focusTerminal(group: group, tab: tab) },
                    onSave: {
                        sessionStore.saveSession(group: group, tab: tab, summary: summaryManager.summary(for: tab.id),
                                         contentReader: summaryManager.contentReader, hookServer: hookServer)
                    },
                    onClose: { closeTerminal(group: group, tab: tab) },
                    windowFrame: sessionStore.cachedFrame(for: tab.id),
                    isAutopilotEnabled: autopilotManager.isEnabled(tabID: tab.id),
                    autopilotState: autopilotManager.sessionState(tabID: tab.id),
                    autopilotCycleCount: autopilotManager.sessions[tab.id]?.cycleCount ?? 0,
                    onToggleAutopilot: {
                        guard let sid = effectiveSID else { return }
                        if autopilotManager.isEnabled(tabID: tab.id) {
                            autopilotManager.disable(tabID: tab.id)
                        } else {
                            autopilotManager.enable(tabID: tab.id, claudeSessionID: sid, group: group, tab: tab)
                        }
                    },
                    onDismissEscalation: {
                        autopilotManager.dismissEscalation(tabID: tab.id)
                    },
                    onTestInject: {
                        WindowFocuser.shared.injectText("# test_inject_\(Int(Date().timeIntervalSince1970))", group: group, tab: tab)
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

    private var savedSessionsSection: some View {
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

                    Text("\(sessionStore.savedSessions.count)")
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)

                    Spacer()

                    if savedExpanded {
                        Button("Clear") {
                            withAnimation { sessionStore.clearSaved() }
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
                ForEach(sessionStore.savedSessions) { session in
                    ClosedSessionRow(
                        session: session,
                        isActive: isSessionActive(session),
                        onRestore: { restoreOrFocus(session) },
                        onDismiss: { withAnimation { sessionStore.dismissSaved(session) } },
                        onRename: { newName in sessionStore.renameSaved(session, to: newName) }
                    )
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

    @State private var optionHeld = false

    private var footer: some View {
        HStack(alignment: .center, spacing: 8) {
            FeedbackView()

            if summaryManager.isSummarizing {
                HStack(spacing: 3) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Summarizing")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .transition(.opacity)
            }

            Spacer()

            Button(action: { showHistory.toggle() }) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
            .help("Session History")

            if updateChecker.updateAvailable, let version = updateChecker.latestVersion {
                Button(action: { showUpdatePopover.toggle() }) {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(.blue)
                            .frame(width: 6, height: 6)
                        Text("v\(version)")
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    }
                    .foregroundStyle(.primary)
                }
                .buttonStyle(.plain)
                .onHover { inside in
                    if inside { NSCursor.pointingHand.push() }
                    else { NSCursor.pop() }
                }
                .popover(isPresented: $showUpdatePopover, arrowEdge: .top) {
                    UpdatePopoverView()
                        .environmentObject(updateChecker)
                }
            } else {
                Text("v\(updateChecker.currentVersion)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.quaternary)
            }

            Button(action: {
                if optionHeld {
                    // Relaunch
                    let url = Bundle.main.bundleURL
                    let task = Process()
                    task.launchPath = "/usr/bin/open"
                    task.arguments = ["-n", url.path]
                    try? task.run()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        NSApp.terminate(nil)
                    }
                } else {
                    NSApp.terminate(nil)
                }
            }) {
                Text(optionHeld ? "Relaunch" : "Quit")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside { NSCursor.pointingHand.push() }
                else { NSCursor.pop() }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(optionKeyMonitor)
    }

    private var optionKeyMonitor: some View {
        OptionKeyMonitorView(isPressed: $optionHeld)
            .frame(width: 0, height: 0)
    }

    // MARK: - Helpers

    /// Check if a saved session's terminal is currently open (Claude session ID match only)
    private func isSessionActive(_ session: SavedSession) -> Bool {
        guard let sid = session.claudeSessionID else { return false }
        for group in appState.terminalGroups {
            for tab in group.tabs {
                if sessionStore.cachedClaudeSessionID(for: tab.id) == sid {
                    return true
                }
            }
        }
        return false
    }

    /// Look up Claude hook state for a tab (uses cached session ID only — no CWD fallback)
    private func claudeState(for tab: TerminalTab) -> ClaudeState? {
        guard let sid = sessionStore.cachedClaudeSessionID(for: tab.id),
              let session = hookServer.sessions[sid] else { return nil }
        // Don't show state for file-discovered sessions unless JSONL polling has confirmed it
        if session.isFileDiscovered && !session.lastEvent.contains("JSONL") { return nil }
        return session.state
    }

    // MARK: - Actions

    private func restoreOrFocus(_ session: SavedSession) {
        Log.info("restoreOrFocus: id=\(session.id.prefix(8)) summary=\(session.summary) claude=\(session.wasClaudeSession) sid=\(session.claudeSessionID ?? "nil") dir=\(session.workingDirectory ?? "nil")", category: "restore")
        if let (group, tab) = findActiveTab(for: session) {
            Log.info("restoreOrFocus: FOCUSING existing tab=\(tab.id) title=\(tab.title) in window=\(group.windowID)", category: "restore")
            focusTerminal(group: group, tab: tab)
        } else {
            Log.info("restoreOrFocus: no active tab found, calling restore()", category: "restore")
            sessionStore.restore(session)
        }
    }

    private func findActiveTab(for session: SavedSession) -> (TerminalGroup, TerminalTab)? {
        guard let sid = session.claudeSessionID else { return nil }
        for group in appState.terminalGroups {
            for tab in group.tabs {
                if sessionStore.cachedClaudeSessionID(for: tab.id) == sid {
                    return (group, tab)
                }
            }
        }
        return nil
    }

    private func focusTerminal(group: TerminalGroup, tab: TerminalTab) {
        appState.touchActivity(tabID: tab.id)
        WindowFocuser.shared.focus(group: group, tab: tab)
    }

    private func closeTerminal(group: TerminalGroup, tab: TerminalTab) {
        WindowFocuser.shared.close(group: group, tab: tab)
    }
}

// MARK: - Closed Session Row

struct ClosedSessionRow: View {
    let session: SavedSession
    let isActive: Bool
    let onRestore: () -> Void
    let onDismiss: () -> Void
    var onRename: ((String) -> Void)? = nil

    @State private var isHovered = false
    @State private var isEditing = false
    @State private var editText = ""

    var body: some View {
        HStack(spacing: 8) {
            // Green dot for active (restored), gray for closed
            Circle()
                .fill(isActive ? Color.green.opacity(0.8) : Color.secondary.opacity(0.4))
                .frame(width: 9, height: 9)
                .frame(width: 14, height: 14)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    if isEditing {
                        TextField("", text: $editText, onCommit: {
                            let trimmed = editText.trimmingCharacters(in: .whitespaces)
                            if !trimmed.isEmpty {
                                onRename?(trimmed)
                            }
                            isEditing = false
                        })
                        .font(.system(size: 13))
                        .textFieldStyle(.plain)
                        .onExitCommand { isEditing = false }
                    } else {
                        Text(session.summary)
                            .font(.system(size: 13))
                            .foregroundStyle(isActive ? .tertiary : .secondary)
                            .lineLimit(1)
                            .onTapGesture(count: 2) {
                                guard onRename != nil else { return }
                                editText = session.summary
                                isEditing = true
                            }
                    }

                    if !isEditing, session.effectiveTag != "term" {
                        SessionTagView(tag: session.effectiveTag)
                    }
                }

                if !session.wasClaudeSession, let dir = session.workingDirectory {
                    Text(dir.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                        .font(.system(size: 10))
                        .foregroundStyle(.quaternary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if isHovered && !isEditing {
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)

                Button(action: onRestore) {
                    Image(systemName: isActive ? "macwindow" : "arrow.uturn.left")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
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
            onRestore()
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

// MARK: - Option Key Monitor

struct OptionKeyMonitorView: NSViewRepresentable {
    @Binding var isPressed: Bool

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.start(binding: $isPressed)
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator() }

    class Coordinator {
        private var monitor: Any?

        func start(binding: Binding<Bool>) {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                binding.wrappedValue = event.modifierFlags.contains(.option)
                return event
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

// MARK: - Session History Window

struct SessionHistoryView: View {
    let sessions: [SavedSession]
    let onRestore: (SavedSession) -> Void
    let onSave: (SavedSession) -> Void
    let onDismiss: (SavedSession) -> Void
    let onClearAll: () -> Void

    @State private var searchText = ""
    @StateObject private var searcher = SessionSearcher()

    private var isSearching: Bool { !searchText.isEmpty }

    private var displaySessions: [SavedSession] {
        if !isSearching { return sessions }
        return searcher.keywordResults.map(\.session)
    }

    /// AI results that aren't already in keyword results
    private var uniqueAIResults: [SavedSession] {
        let keywordIDs = Set(searcher.keywordResults.map(\.session.id))
        return searcher.aiResults.filter { !keywordIDs.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Session History")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if !sessions.isEmpty {
                    Button("Clear All") { onClearAll() }
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)

            // Search bar
            if !sessions.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                    TextField("Search sessions...", text: $searchText)
                        .font(.system(size: 13))
                        .textFieldStyle(.plain)
                    if isSearching {
                        Button(action: {
                            searchText = ""
                            searcher.cancelAISearch()
                            searcher.keywordResults = []
                            searcher.aiResults = []
                        }) {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 12))
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(0.04))
                )
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
                .onChange(of: searchText) { _, query in
                    searcher.keywordSearch(query: query, sessions: sessions)
                    searcher.aiSearch(query: query, sessions: sessions)
                }
            }

            Divider()

            if sessions.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No session history")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if isSearching && displaySessions.isEmpty && !searcher.isAISearching && uniqueAIResults.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(.tertiary)
                    Text("No matches for \"\(searchText)\"")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 1) {
                        // Keyword results (or all sessions when not searching)
                        if isSearching && !displaySessions.isEmpty {
                            sectionHeader("Matches")
                        }
                        ForEach(displaySessions) { session in
                            historyRow(session)
                        }

                        // AI results section
                        if isSearching {
                            if searcher.isAISearching {
                                aiLoadingRow
                            } else if !uniqueAIResults.isEmpty {
                                sectionHeader("AI Results")
                                ForEach(uniqueAIResults) { session in
                                    historyRow(session)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
        .frame(width: 420, height: 400)
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }

    private var aiLoadingRow: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Searching with AI...")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func historyRow(_ session: SavedSession) -> some View {
        HStack(spacing: 10) {
            // Status
            Circle()
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.summary)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    if session.effectiveTag != "term" {
                        SessionTagView(tag: session.effectiveTag)
                    }
                }

                HStack(spacing: 8) {
                    if let dir = session.workingDirectory {
                        Text(dir.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~"))
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }

                    Text(formatDate(session.closedAt))
                        .font(.system(size: 11))
                        .foregroundStyle(.quaternary)
                }
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button(action: { onSave(session) }) {
                    Image(systemName: "bookmark")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Save to saved sessions")

                Button(action: { onRestore(session) }) {
                    Image(systemName: "arrow.uturn.left")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Button(action: { onDismiss(session) }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .foregroundStyle(.quaternary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        let seconds = -date.timeIntervalSinceNow
        if seconds < 86400 {
            f.dateFormat = "h:mm a"
        } else {
            f.dateFormat = "MMM d, h:mm a"
        }
        return f.string(from: date)
    }
}
