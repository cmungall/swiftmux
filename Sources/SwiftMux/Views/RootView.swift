import SwiftUI

struct RootView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var terminalState = TmuxTerminalState()
    @State private var commandPalettePresented = false

    var body: some View {
        NavigationView {
            SessionSidebarView(sessionManager: sessionManager)
            SessionDetailView(
                session: sessionManager.selectedSession,
                lastRefresh: sessionManager.lastRefresh,
                terminalState: terminalState
            )
        }
        .background(AppTheme.windowBackground)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Button {
                    Task {
                        await sessionManager.refresh()
                    }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Button {
                    commandPalettePresented = true
                } label: {
                    Label("Command Palette", systemImage: "magnifyingglass")
                }


            }
        }
        .sheet(isPresented: $commandPalettePresented) {
            CommandPaletteView(sessions: sessionManager.sessions) { session in
                sessionManager.selectedSessionID = session.id
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMuxOpenCommandPalette)) { _ in
            commandPalettePresented = true
        }
        .task {
            sessionManager.startPolling()
        }
    }
}

private enum SidebarTab: String, CaseIterable {
    case recent = "Recent"
    case repo = "By Repo"
}

private struct SessionSidebarView: View {
    @ObservedObject var sessionManager: SessionManager
    @State private var tab: SidebarTab = .recent

    var body: some View {
        VStack(spacing: 0) {
            // Compact tab picker — stays within sidebar width
            Picker("View", selection: $tab) {
                ForEach(SidebarTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            List(selection: $sessionManager.selectedSessionID) {
                if let pollError = sessionManager.pollError {
                    Section {
                        Text(pollError)
                            .font(.caption)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                    }
                }

                switch tab {
                case .recent:
                    ForEach(sessionManager.sessionsByRecency) { session in
                        SessionRowView(session: session, onKill: { sessionManager.killSession($0) })
                            .tag(session.id)
                    }
                case .repo:
                    ForEach(sessionManager.sessionGroups) { group in
                        Section(group.name) {
                            ForEach(group.sessions) { session in
                                SessionRowView(session: session, onKill: { sessionManager.killSession($0) })
                                    .tag(session.id)
                            }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .background(AppTheme.sidebarBackground)
        }
        .background(AppTheme.sidebarBackground)
        .navigationTitle("SwiftMux")
    }
}

private struct SessionRowView: View {
    let session: SessionInfo
    var onKill: ((SessionInfo) -> Void)?
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Circle()
                    .fill(session.status.color)
                    .frame(width: 8, height: 8)

                Text(session.name)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .lineLimit(1)

                Spacer(minLength: 8)

                if hovering {
                    Button {
                        onKill?(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(AppTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .help("Kill session")
                }

                Text(session.process)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(AppTheme.mutedText)
                    .lineLimit(1)
            }

            Text(session.detailSummary)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundColor(AppTheme.mutedText)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(session.repoGroupName)
                if let branch = session.branchName {
                    Text(branch)
                }
                Text(session.status.label)
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(AppTheme.mutedText)
        }
        .padding(.vertical, 6)
        .onHover { hovering = $0 }
    }
}

private struct SessionDetailView: View {
    let session: SessionInfo?
    let lastRefresh: Date?
    @ObservedObject var terminalState: TmuxTerminalState

    var body: some View {
        ZStack {
            AppTheme.windowBackground
                .ignoresSafeArea()

            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    // Compact header: name + chips on one line
                    HStack(alignment: .center, spacing: 12) {
                        Text(session.name)
                            .font(.system(size: 18, weight: .bold, design: .rounded))

                        MetadataChip(text: session.status.label, tint: session.status.color)
                        MetadataChip(text: session.process)
                        if let branch = session.branchName {
                            MetadataChip(text: branch)
                        }

                        Spacer()

                        // Inline metadata
                        Text(terminalState.currentDirectory ?? session.shortenedWorkingDirectory)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(AppTheme.mutedText)
                            .lineLimit(1)
                    }

                    if let error = terminalState.lastError {
                        HStack {
                            Text(error)
                                .font(.system(size: 11, weight: .medium, design: .rounded))
                                .foregroundColor(.red.opacity(0.9))

                            Spacer(minLength: 12)

                            Button("Reconnect") {
                                terminalState.requestReconnect(for: session.name)
                            }
                        }
                    }

                    TmuxTerminalView(session: session, terminalState: terminalState)
                        .id(terminalState.resetToken)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(AppTheme.panelBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                }
                .padding(12)
            } else {
                Text("No tmux sessions found.")
                    .foregroundColor(AppTheme.mutedText)
            }
        }
    }
}

private struct MetadataChip: View {
    let text: String
    var tint: Color = AppTheme.elevatedBackground

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(tint.opacity(0.85))
            .clipShape(Capsule())
    }
}

private struct MetadataLine: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(AppTheme.mutedText)
                .frame(width: 76, alignment: .leading)

            Text(value)
                .font(.system(size: 12, weight: .regular, design: .monospaced))
                .textSelection(.enabled)
        }
    }
}
