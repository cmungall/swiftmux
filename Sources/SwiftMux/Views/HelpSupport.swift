import SwiftUI

enum SwiftMuxHelpTopic: String, CaseIterable, Identifiable {
    case overview
    case shortcuts
    case sessions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview:
            return "Overview"
        case .shortcuts:
            return "Shortcuts"
        case .sessions:
            return "Session Actions"
        }
    }

    var headline: String {
        switch self {
        case .overview:
            return "SwiftMux is built to move between tmux sessions without leaving the keyboard."
        case .shortcuts:
            return "The app is fastest when you treat the sidebar and command palette as your navigation layer."
        case .sessions:
            return "Each session row exposes lightweight inspection and recovery actions before you attach."
        }
    }
}

struct SwiftMuxHelpSheet: View {
    @Binding var selectedTopic: SwiftMuxHelpTopic
    let onOpenPalette: () -> Void
    let onFocusSidebarSearch: () -> Void
    let onRefresh: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SwiftMux Help")
                        .font(.system(size: 24, weight: .bold, design: .rounded))

                    Text(selectedTopic.headline)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 20)

                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            Picker("Topic", selection: $selectedTopic) {
                ForEach(SwiftMuxHelpTopic.allCases) { topic in
                    Text(topic.title).tag(topic)
                }
            }
            .pickerStyle(.segmented)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    switch selectedTopic {
                    case .overview:
                        HelpCard(
                            title: "Daily flow",
                            text: "Use the sidebar for scanning and lightweight filtering, then drop into the terminal pane once you attach to a session."
                        )
                        HelpCard(
                            title: "Command palette",
                            text: "Press Cmd-K to fuzzy-search by session name, repo, branch, process, or description and switch immediately."
                        )
                        HelpCard(
                            title: "Recovery",
                            text: "If the tmux client detaches or switching fails, the detail pane surfaces the error and offers a Reconnect action."
                        )
                    case .shortcuts:
                        ShortcutCard(
                            title: "Navigation",
                            shortcuts: [
                                ("Cmd-F", "Focus the sidebar filter"),
                                ("Cmd-K", "Open the command palette"),
                                ("Cmd-1...9", "Jump to one of the first visible sessions")
                            ]
                        )
                        ShortcutCard(
                            title: "Lists and sheets",
                            shortcuts: [
                                ("Up / Down", "Move through sidebar rows or command palette results"),
                                ("Enter", "Switch to the highlighted command palette result"),
                                ("Esc", "Dismiss the command palette")
                            ]
                        )
                        ShortcutCard(
                            title: "Maintenance",
                            shortcuts: [
                                ("Cmd-R", "Refresh sessions from tmux-pilot"),
                                ("Scroll", "Send tmux mouse-wheel events inside the terminal pane")
                            ]
                        )
                    case .sessions:
                        HelpCard(
                            title: "Sidebar row actions",
                            text: "Right-click a session to peek at recent output, copy its name, or kill it without switching."
                        )
                        HelpCard(
                            title: "Status chips",
                            text: "Session badges show whether work is active, idle, done, or waiting on a human response."
                        )
                        HelpCard(
                            title: "Metadata",
                            text: "Repo, branch, process, and working directory stay visible in the detail pane so you can confirm context before typing."
                        )
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
                .overlay(AppTheme.border)

            HStack(spacing: 10) {
                HelpActionButton(title: "Focus Search", systemImage: "magnifyingglass") {
                    dismiss()
                    onFocusSidebarSearch()
                }

                HelpActionButton(title: "Open Palette", systemImage: "command") {
                    dismiss()
                    onOpenPalette()
                }

                HelpActionButton(title: "Refresh", systemImage: "arrow.clockwise") {
                    dismiss()
                    onRefresh()
                }
            }
        }
        .padding(24)
        .frame(width: 720, height: 560, alignment: .topLeading)
        .background(AppTheme.panelBackground)
    }
}

struct SidebarGuidanceCard: View {
    let onOpenHelp: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "questionmark.circle")
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(AppTheme.activeAccent)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 4) {
                Text("Cmd-F filters the sidebar. Cmd-K jumps anywhere. Right-click a row for Peek, Copy Name, or Kill.")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))

                Button("Open Help") {
                    onOpenHelp()
                }
                .buttonStyle(.link)
                .font(.system(size: 11, weight: .semibold, design: .rounded))
            }

            Spacer(minLength: 0)

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundColor(AppTheme.mutedText)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss tips")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(AppTheme.elevatedBackground.opacity(0.9))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct SessionGuidanceCard: View {
    let statusMessage: String
    let lastRefresh: Date?
    let onOpenHelp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "bolt.horizontal.circle")
                    .foregroundColor(AppTheme.activeAccent)

                Text(statusMessage)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))

                Spacer(minLength: 8)

                if let lastRefresh {
                    Text("Updated \(lastRefresh, format: .dateTime.hour().minute())")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundColor(AppTheme.mutedText)
                }
            }

            HStack(spacing: 12) {
                Text("Scroll in the terminal for tmux copy-mode.")
                Text("Cmd-K switches sessions.")
                Button("Help") {
                    onOpenHelp()
                }
                .buttonStyle(.link)
            }
            .font(.system(size: 10, weight: .medium, design: .rounded))
            .foregroundColor(AppTheme.mutedText)
        }
        .padding(12)
        .background(AppTheme.panelBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

private struct HelpCard: View {
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))

            Text(text)
                .font(.system(size: 12, weight: .regular, design: .rounded))
                .foregroundColor(AppTheme.mutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.windowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct ShortcutCard: View {
    let title: String
    let shortcuts: [(String, String)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: .rounded))

            ForEach(Array(shortcuts.enumerated()), id: \.offset) { _, shortcut in
                HStack(alignment: .top, spacing: 12) {
                    Text(shortcut.0)
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundColor(.white.opacity(0.96))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppTheme.elevatedBackground)
                        .clipShape(Capsule())

                    Text(shortcut.1)
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundColor(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.windowBackground)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(AppTheme.border, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

private struct HelpActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .tint(AppTheme.elevatedBackground)
    }
}
