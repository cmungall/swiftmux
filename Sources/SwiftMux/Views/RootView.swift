import AppKit
import SwiftMuxCore
import SwiftUI

struct RootView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var terminalState = TmuxTerminalState()
    @State private var commandPalettePresented = false
    @State private var helpPresented = false
    @State private var helpTopic: SwiftMuxHelpTopic = .overview

    var body: some View {
        NavigationView {
            SessionSidebarView(
                sessionManager: sessionManager,
                onOpenHelp: { presentHelp() }
            )
            SessionDetailView(
                session: sessionManager.selectedSession,
                lastRefresh: sessionManager.lastRefresh,
                terminalState: terminalState,
                onOpenHelp: { presentHelp(topic: .sessions) },
                onRefresh: refreshSessions
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
                .help("Reload tmux sessions from tmux-pilot")

                Button {
                    commandPalettePresented = true
                } label: {
                    Label("Command Palette", systemImage: "magnifyingglass")
                }
                .help("Jump to a tmux session with fuzzy search")
            }
        }
        .sheet(isPresented: $commandPalettePresented) {
            CommandPaletteView(sessions: sessionManager.sessions) { session in
                sessionManager.selectedSessionID = session.id
            }
        }
        .sheet(isPresented: $helpPresented) {
            SwiftMuxHelpSheet(
                selectedTopic: $helpTopic,
                onOpenPalette: { commandPalettePresented = true },
                onFocusSidebarSearch: focusSidebarSearch,
                onRefresh: refreshSessions
            )
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMuxOpenCommandPalette)) { _ in
            commandPalettePresented = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMuxShowHelp)) { notification in
            let topic = (notification.userInfo?["topic"] as? String)
                .flatMap(SwiftMuxHelpTopic.init(rawValue:))
            presentHelp(topic: topic ?? .overview)
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMuxRefreshSessions)) { _ in
            refreshSessions()
        }
        .task {
            sessionManager.startPolling()
        }
    }

    private func presentHelp(topic: SwiftMuxHelpTopic = .overview) {
        helpTopic = topic
        helpPresented = true
    }

    private func focusSidebarSearch() {
        NotificationCenter.default.post(name: .swiftMuxFocusSidebarSearch, object: nil)
    }

    private func refreshSessions() {
        Task {
            await sessionManager.refresh()
        }
    }
}

private enum SidebarTab: String, CaseIterable {
    case recent = "Recent"
    case repo = "By Repo"
}

/// Fuzzy match à la fzf: characters must appear in order but not contiguously.
private func fuzzyMatch(query: String, in text: String) -> Bool {
    guard !query.isEmpty else { return true }
    var qi = query.lowercased().makeIterator()
    var need = qi.next()
    for ch in text.lowercased() {
        if ch == need {
            need = qi.next()
            if need == nil { return true }
        }
    }
    return false
}

private struct SessionSidebarView: View {
    private enum FocusTarget: Hashable {
        case search
        case list
    }

    @ObservedObject var sessionManager: SessionManager
    let onOpenHelp: () -> Void
    @State private var tab: SidebarTab = .recent
    @State private var searchText = ""
    @FocusState private var focusTarget: FocusTarget?

    private var visibleRecentSessions: [SessionInfo] {
        sessionManager.sessionsByRecency.filter(matches)
    }

    private var visibleRepoSessions: [SessionInfo] {
        sessionManager.sessionGroups.flatMap { group in
            group.sessions.filter(matches)
        }
    }

    private var visibleSessions: [SessionInfo] {
        switch tab {
        case .recent:
            return visibleRecentSessions
        case .repo:
            return visibleRepoSessions
        }
    }

    private func matches(_ session: SessionInfo) -> Bool {
        guard !searchText.isEmpty else { return true }
        // Match against name, desc, repo, branch — same fields fzf sees in tp
        let haystack = [
            session.name,
            session.metadata.desc ?? "",
            session.repoGroupName,
            session.branchName ?? "",
            session.process,
        ].joined(separator: " ")
        return fuzzyMatch(query: searchText, in: haystack)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Search bar — compact, always visible
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundColor(AppTheme.mutedText)
                TextField("Filter…", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .focused($focusTarget, equals: .search)
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(AppTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(AppTheme.panelBackground)
            .help("Filter by session name, repo, branch, process, or description")

            // Tab picker
            Picker("View", selection: $tab) {
                ForEach(SidebarTab.allCases, id: \.self) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            SidebarGuidanceCard(onOpenHelp: onOpenHelp)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

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
                    ForEach(visibleRecentSessions) { session in
                        SessionRowView(
                            session: session,
                            onKill: { sessionManager.killSession($0) },
                            onPeek: { session in
                                try await sessionManager.peekOutput(for: session)
                            }
                        )
                            .tag(session.id)
                    }
                case .repo:
                    ForEach(sessionManager.sessionGroups) { group in
                        let filtered = group.sessions.filter(matches)
                        if !filtered.isEmpty {
                            Section {
                                ForEach(filtered) { session in
                                    SessionRowView(
                                        session: session,
                                        onKill: { sessionManager.killSession($0) },
                                        onPeek: { session in
                                            try await sessionManager.peekOutput(for: session)
                                        }
                                    )
                                        .tag(session.id)
                                }
                            } header: {
                                SessionRepoGroupHeader(name: group.name, count: filtered.count)
                            }
                        }
                    }
                }
            }
            .focusable()
            .focused($focusTarget, equals: .list)
            .onMoveCommand { direction in
                guard focusTarget == .list else {
                    return
                }

                switch direction {
                case .down:
                    moveSelection(by: 1)
                case .up:
                    moveSelection(by: -1)
                default:
                    break
                }
            }
            .onTapGesture {
                focusTarget = .list
            }
            .listStyle(.sidebar)
            .background(AppTheme.sidebarBackground)
            .help("Select a session to attach. Right-click rows for Peek, Copy Name, or Kill.")
        }
        .background(AppTheme.sidebarBackground)
        .navigationTitle("SwiftMux")
        .onAppear {
            focusTarget = .list
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMuxFocusSidebarSearch)) { _ in
            focusTarget = .search
        }
        .onReceive(NotificationCenter.default.publisher(for: .swiftMuxSelectSidebarSessionIndex)) { notification in
            guard let index = notification.userInfo?["index"] as? Int else {
                return
            }

            selectVisibleSession(at: index)
            focusTarget = .list
        }
    }

    private func moveSelection(by offset: Int) {
        guard !visibleSessions.isEmpty else {
            return
        }

        let nextIndex: Int
        if let selectedSessionID = sessionManager.selectedSessionID,
           let currentIndex = visibleSessions.firstIndex(where: { $0.id == selectedSessionID }) {
            nextIndex = min(max(currentIndex + offset, 0), visibleSessions.count - 1)
        } else {
            nextIndex = offset >= 0 ? 0 : visibleSessions.count - 1
        }

        sessionManager.selectedSessionID = visibleSessions[nextIndex].id
    }

    private func selectVisibleSession(at index: Int) {
        guard visibleSessions.indices.contains(index) else {
            return
        }

        sessionManager.selectedSessionID = visibleSessions[index].id
    }
}

private struct SessionRowView: View {
    let session: SessionInfo
    var onKill: ((SessionInfo) -> Void)?
    var onPeek: ((SessionInfo) async throws -> String)?
    @State private var hovering = false
    @State private var peekPresented = false
    @State private var peekLoading = false
    @State private var peekOutput = ""
    @State private var peekError: String?
    @State private var peekTask: Task<Void, Never>?

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
        .contextMenu {
            Button("Peek") {
                presentPeek()
            }

            Button("Copy Name") {
                copyNameToPasteboard()
            }

            Divider()

            Button("Kill") {
                onKill?(session)
            }
        }
        .popover(isPresented: $peekPresented, arrowEdge: .trailing) {
            SessionPeekPopoverView(
                sessionName: session.name,
                isLoading: peekLoading,
                output: peekOutput,
                error: peekError
            )
        }
        .onDisappear {
            peekTask?.cancel()
            peekTask = nil
        }
    }

    private func presentPeek() {
        peekPresented = true
        peekLoading = true
        peekOutput = ""
        peekError = nil
        peekTask?.cancel()
        peekTask = Task {
            do {
                let output = try await onPeek?(session) ?? ""
                await MainActor.run {
                    peekOutput = output
                    peekLoading = false
                }
            } catch is CancellationError {
                await MainActor.run {
                    peekLoading = false
                }
            } catch {
                await MainActor.run {
                    peekError = error.localizedDescription
                    peekLoading = false
                }
            }
        }
    }

    private func copyNameToPasteboard() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(session.name, forType: .string)
    }
}

private struct SessionPeekPopoverView: View {
    let sessionName: String
    let isLoading: Bool
    let output: String
    let error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Peek: \(sessionName)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Loading last 50 lines…")
                        .foregroundColor(AppTheme.mutedText)
                }
                .font(.system(size: 12, weight: .medium, design: .rounded))
            } else if let error {
                Text(error)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .textSelection(.enabled)
            } else {
                ScrollView {
                    Text(output.isEmpty ? "No output returned." : output)
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                }
                .background(AppTheme.windowBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(16)
        .frame(width: 540, height: 340, alignment: .topLeading)
        .background(AppTheme.panelBackground)
    }
}

private struct SessionRepoGroupHeader: View {
    let name: String
    let count: Int

    var body: some View {
        HStack(spacing: 8) {
            Text(name)

            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(AppTheme.elevatedBackground)
                .clipShape(Capsule())
        }
    }
}

private struct SessionDetailView: View {
    let session: SessionInfo?
    let lastRefresh: Date?
    @ObservedObject var terminalState: TmuxTerminalState
    let onOpenHelp: () -> Void
    let onRefresh: () -> Void

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

                    SessionGuidanceCard(
                        statusMessage: terminalState.statusMessage,
                        lastRefresh: lastRefresh,
                        onOpenHelp: onOpenHelp
                    )

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
                        .help("Attached tmux client. Scroll wheel input is forwarded to tmux mouse mode.")
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.border, lineWidth: 1)
                        )
                }
                .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    Text("No tmux sessions found")
                        .font(.system(size: 22, weight: .bold, design: .rounded))

                    Text("SwiftMux reads sessions from `tp ls --json`. Start tmux work, then refresh to populate the sidebar.")
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundColor(AppTheme.mutedText)
                        .fixedSize(horizontal: false, vertical: true)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. Make sure tmux is running.")
                        Text("2. Install `tmux-pilot` so `tp` is available.")
                        Text("3. Use Cmd-R to refresh once sessions exist.")
                    }
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))

                    HStack(spacing: 10) {
                        Button("Refresh") {
                            onRefresh()
                        }

                        Button("Open Help") {
                            onOpenHelp()
                        }
                    }
                }
                .padding(24)
                .frame(maxWidth: 520, alignment: .leading)
                .background(AppTheme.panelBackground)
                .overlay(
                    RoundedRectangle(cornerRadius: 14)
                        .stroke(AppTheme.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 14))
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
