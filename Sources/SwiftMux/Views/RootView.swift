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

                Toggle(isOn: $sessionManager.groupByRepo) {
                    Label("Group by Repo", systemImage: sessionManager.groupByRepo ? "square.grid.2x2.fill" : "list.bullet")
                }
                .toggleStyle(.button)
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

private struct SessionSidebarView: View {
    @ObservedObject var sessionManager: SessionManager

    var body: some View {
        List(selection: $sessionManager.selectedSessionID) {
            if let pollError = sessionManager.pollError {
                Section {
                    Text(pollError)
                        .font(.caption)
                        .foregroundColor(.red)
                        .textSelection(.enabled)
                }
            }

            if sessionManager.groupByRepo {
                ForEach(sessionManager.sessionGroups) { group in
                    Section(group.name) {
                        ForEach(group.sessions) { session in
                            SessionRowView(session: session)
                                .tag(session.id)
                        }
                    }
                }
            } else {
                Section("All Sessions") {
                    ForEach(sessionManager.sessions) { session in
                        SessionRowView(session: session)
                            .tag(session.id)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .background(AppTheme.sidebarBackground)
        .navigationTitle("SwiftMux")
    }
}

private struct SessionRowView: View {
    let session: SessionInfo

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
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(session.name)
                            .font(.system(size: 28, weight: .bold, design: .rounded))

                        Text(session.descriptionText ?? "tmux session")
                            .foregroundColor(AppTheme.mutedText)

                        HStack(spacing: 12) {
                            MetadataChip(text: session.repoGroupName)
                            MetadataChip(text: session.status.label, tint: session.status.color)
                            if let branch = session.branchName {
                                MetadataChip(text: branch)
                            }
                            MetadataChip(text: session.process)
                        }
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Session Metadata")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(AppTheme.mutedText)

                        VStack(alignment: .leading, spacing: 10) {
                            MetadataLine(label: "Status", value: terminalState.statusMessage)
                            MetadataLine(label: "Directory", value: terminalState.currentDirectory ?? session.shortenedWorkingDirectory)
                            MetadataLine(label: "Title", value: terminalState.terminalTitle)
                            if let branch = session.branchName {
                                MetadataLine(label: "Branch", value: branch)
                            }
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppTheme.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 14)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 14))

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Terminal")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                            .foregroundColor(AppTheme.mutedText)

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
                            .padding(.bottom, 4)
                        }

                        TmuxTerminalView(session: session, terminalState: terminalState)
                            .id(terminalState.resetToken)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(AppTheme.panelBackground)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .background(AppTheme.panelBackground)
                    .overlay(
                        RoundedRectangle(cornerRadius: 18)
                            .stroke(AppTheme.border, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 18))

                    if let lastRefresh {
                        Text("Last refresh \(lastRefresh.formatted(date: .omitted, time: .standard))")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(AppTheme.mutedText)
                    }
                }
                .padding(28)
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
