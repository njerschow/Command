import SwiftUI

struct TerminalListView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            terminalList

            Divider()
                .padding(.horizontal, 8)

            footer
        }
        .frame(width: 320)
        .fixedSize(horizontal: true, vertical: true)
    }

    // MARK: - Terminal List

    @ViewBuilder
    private var terminalList: some View {
        if appState.terminalGroups.isEmpty {
            emptyState
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(appState.terminalGroups) { group in
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
            // Single tab: flat row with app name as subtitle
            singleTabRow(group: group, tab: tab)
        } else {
            // Multi-tab: section header + rows
            multiTabSection(group: group)
        }
    }

    private func singleTabRow(group: TerminalGroup, tab: TerminalTab) -> some View {
        let globalIdx = appState.globalIndex(for: group)
        return TerminalRowView(tab: tab, shortcutIndex: globalIdx) {
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
                TerminalRowView(tab: tab, shortcutIndex: startIndex + index) {
                    focusTerminal(group: group, tab: tab)
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
        HStack {
            Button(action: { /* TODO: feedback */ }) {
                HStack(spacing: 4) {
                    Image(systemName: "bubble.left")
                        .font(.system(size: 10))
                    Text("Suggest")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .onHover { inside in
                if inside {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }

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
        // TODO: implement window focusing
        print("Focus: \(group.displayName) → \(tab.title)")
    }
}
