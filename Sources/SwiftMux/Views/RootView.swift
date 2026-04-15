import AppKit
import SwiftUI

struct RootView: View {
    @StateObject private var sessionManager = SessionManager()
    @StateObject private var terminalState = TmuxTerminalState()
    @State private var commandPalettePresented = false
    @State private var newSessionSheetPresented = false
    @State private var newSessionDirectory = ""
    @State private var newSessionError: String?
    @State private var newSessionInFlight = false
    @State private var creationAlertMessage: String?
    @State private var helpPresented = false
    @State private var helpTopic: SwiftMuxHelpTopic = .overview

    var body: some View {
        NavigationView {
            SessionSidebarView(
                sessionManager: sessionManager,
                onOpenHelp: { presentHelp() },
                onCreateInDirectory: { directory in
                    createSession(in: directory)
                }
            )
            SessionDetailView(
                session: sessionManager.selectedSession,
                lastRefresh: sessionManager.lastRefresh,
                terminalState: terminalState,
                onOpenHelp: { presentHelp(topic: .sessions) },
                onRefresh: refreshSessions,
                onRename: { session, name in
                    try await sessionManager.renameSession(session, to: name)
                },
                onKill: { sessionManager.killSession($0) }
            )
        }
        .background(AppTheme.windowBackground)
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    if let selectedRepoTarget {
                        Button("In Selected Repo (\(selectedRepoTarget.name))") {
                            createSession(in: selectedRepoTarget.path)
                        }
                    }

                    if let selectedFolderTarget,
                       selectedFolderTarget.path != selectedRepoTarget?.path {
                        Button("In Selected Folder (\(selectedFolderTarget.name))") {
                            createSession(in: selectedFolderTarget.path)
                        }
                    }

                    if !recentRepoTargets.isEmpty {
                        Divider()

                        Menu("Recent Repos") {
                            ForEach(recentRepoTargets) { target in
                                Button(target.name) {
                                    createSession(in: target.path)
                                }
                            }
                        }
                    }

                    Divider()

                    Button("Other…") {
                        presentNewSessionSheet()
                    }
                } label: {
                    Label("New", systemImage: "plus")
                }

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
                sessionManager.selectSession(session)
            }
        }
        .sheet(isPresented: $newSessionSheetPresented) {
            NewSessionSheetView(
                directory: $newSessionDirectory,
                errorMessage: newSessionError,
                isSubmitting: newSessionInFlight,
                onCancel: {
                    guard !newSessionInFlight else {
                        return
                    }

                    newSessionSheetPresented = false
                },
                onSubmit: submitNewSession
            )
        }
        .alert("Couldn’t create session", isPresented: creationAlertPresented) {
            Button("OK", role: .cancel) {
                creationAlertMessage = nil
            }
        } message: {
            Text(creationAlertMessage ?? "")
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

    private var creationAlertPresented: Binding<Bool> {
        Binding(
            get: { creationAlertMessage != nil },
            set: { isPresented in
                if !isPresented {
                    creationAlertMessage = nil
                }
            }
        )
    }

    private var selectedRepoTarget: SessionCreationTarget? {
        guard let session = sessionManager.selectedSession,
              let repoPath = session.repoRootPath else {
            return nil
        }

        return SessionCreationTarget(path: repoPath, name: session.repoGroupName)
    }

    private var selectedFolderTarget: SessionCreationTarget? {
        guard let session = sessionManager.selectedSession else {
            return nil
        }

        return SessionCreationTarget(path: session.resolvedWorkingDirectory, name: session.folderGroupName)
    }

    private var recentRepoTargets: [SessionCreationTarget] {
        var seen: Set<String> = []
        var targets: [SessionCreationTarget] = []

        for session in sessionManager.orderedSessions(using: .activity) {
            guard let repoPath = session.repoRootPath,
                  seen.insert(repoPath).inserted else {
                continue
            }

            targets.append(SessionCreationTarget(path: repoPath, name: session.repoGroupName))

            if targets.count == 12 {
                break
            }
        }

        return targets
    }

    private func presentNewSessionSheet(prefilledDirectory: String = "") {
        newSessionDirectory = prefilledDirectory
        newSessionError = nil
        newSessionInFlight = false
        newSessionSheetPresented = true
    }

    private func submitNewSession() {
        let trimmedDirectory = newSessionDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else {
            newSessionError = "Repo or folder path cannot be empty."
            return
        }

        newSessionError = nil
        newSessionInFlight = true

        Task {
            do {
                try await sessionManager.createSession(in: trimmedDirectory)
                await MainActor.run {
                    newSessionInFlight = false
                    newSessionSheetPresented = false
                }
            } catch {
                await MainActor.run {
                    newSessionInFlight = false
                    newSessionError = error.localizedDescription
                }
            }
        }
    }

    private func createSession(in directory: String) {
        Task {
            do {
                try await sessionManager.createSession(in: directory)
            } catch {
                await MainActor.run {
                    creationAlertMessage = error.localizedDescription
                }
            }
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

private struct SessionCreationTarget: Identifiable, Hashable {
    let path: String
    let name: String

    var id: String { path }
}

private enum SidebarTab: String, CaseIterable {
    case recent = "Recent"
    case repo = "By Repo"
    case folder = "By Folder"
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
    @AppStorage("swiftmux.sidebar.ordering-mode")
    private var orderingModeStorage = SessionOrderingMode.activity.rawValue
    @State private var tab: SidebarTab = .recent
    @State private var searchText = ""
    @FocusState private var focusTarget: FocusTarget?
    var onCreateInDirectory: ((String) -> Void)?

    private var orderingMode: SessionOrderingMode {
        switch orderingModeStorage {
        case "last-send":
            return .activity
        default:
            return SessionOrderingMode(rawValue: orderingModeStorage) ?? .activity
        }
    }

    private var orderingModeBinding: Binding<SessionOrderingMode> {
        Binding(
            get: { orderingMode },
            set: { orderingModeStorage = $0.rawValue }
        )
    }

    private var visibleRecentSessions: [SessionInfo] {
        sessionManager.orderedSessions(using: orderingMode).filter(matches)
    }

    private var visibleRepoGroups: [SessionGroup] {
        sessionManager.orderedRepoGroups(using: orderingMode).compactMap(filteredGroup)
    }

    private var visibleFolderGroups: [SessionGroup] {
        sessionManager.orderedFolderGroups(using: orderingMode).compactMap(filteredGroup)
    }

    private var visibleRepoSessions: [SessionInfo] {
        visibleRepoGroups.flatMap(\.sessions)
    }

    private var visibleFolderSessions: [SessionInfo] {
        visibleFolderGroups.flatMap(\.sessions)
    }

    private var visibleSessions: [SessionInfo] {
        switch tab {
        case .recent:
            return visibleRecentSessions
        case .repo:
            return visibleRepoSessions
        case .folder:
            return visibleFolderSessions
        }
    }

    private func filteredGroup(_ group: SessionGroup) -> SessionGroup? {
        let filteredSessions = group.sessions.filter(matches)
        guard !filteredSessions.isEmpty else {
            return nil
        }

        return SessionGroup(
            key: group.key,
            name: group.name,
            sessions: filteredSessions,
            creationPath: group.creationPath
        )
    }

    private func matches(_ session: SessionInfo) -> Bool {
        guard !searchText.isEmpty else { return true }
        // Match against name, desc, repo, branch — same fields fzf sees in tp
        let haystack = [
            session.name,
            session.metadata.desc ?? "",
            session.repoGroupName,
            session.folderGroupName,
            session.branchName ?? "",
            session.process,
        ].joined(separator: " ")
        return fuzzyMatch(query: searchText, in: haystack)
    }

    private var selectionBinding: Binding<SessionInfo.ID?> {
        Binding(
            get: { sessionManager.selectedSessionID },
            set: { sessionManager.selectSession(id: $0) }
        )
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

            VStack(spacing: 6) {
                Picker("View", selection: $tab) {
                    ForEach(SidebarTab.allCases, id: \.self) { t in
                        Text(t.rawValue).tag(t)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    if sessionManager.hiddenSessionCount > 0 {
                        Button {
                            sessionManager.unhideAllSessions()
                        } label: {
                            Label("Show Hidden (\(sessionManager.hiddenSessionCount))", systemImage: "eye")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundColor(AppTheme.mutedText)
                        }
                        .buttonStyle(.plain)
                    }

                    Spacer()

                    Picker("Order", selection: orderingModeBinding) {
                        ForEach(SessionOrderingMode.allCases, id: \.self) { mode in
                            Text(mode.shortLabel).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .help("Choose how sessions are ordered")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)

            SidebarGuidanceCard(onOpenHelp: onOpenHelp)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)

            List(selection: selectionBinding) {
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
                            contextLabel: session.repoGroupName,
                            contextHelp: session.repoRootPath,
                            onSelect: { sessionManager.selectSession($0) },
                            onHide: { sessionManager.hideSession($0) },
                            onPeek: { session in
                                try await sessionManager.peekOutput(for: session)
                            }
                        )
                            .tag(session.id)
                    }
                case .repo:
                    ForEach(visibleRepoGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRowView(
                                    session: session,
                                    contextLabel: session.repoScopedLocationName,
                                    contextHelp: session.resolvedWorkingDirectory,
                                    onSelect: { sessionManager.selectSession($0) },
                                    onHide: { sessionManager.hideSession($0) },
                                    onPeek: { session in
                                        try await sessionManager.peekOutput(for: session)
                                    }
                                )
                                    .tag(session.id)
                            }
                        } header: {
                            SessionGroupHeader(
                                name: group.name,
                                count: group.sessions.count,
                                helpText: group.creationPath,
                                onCreate: group.creationPath.map { path in
                                    {
                                        onCreateInDirectory?(path)
                                    }
                                }
                            )
                        }
                    }
                case .folder:
                    ForEach(visibleFolderGroups) { group in
                        Section {
                            ForEach(group.sessions) { session in
                                SessionRowView(
                                    session: session,
                                    contextLabel: session.repoGroupName,
                                    contextHelp: session.repoRootPath,
                                    onSelect: { sessionManager.selectSession($0) },
                                    onHide: { sessionManager.hideSession($0) },
                                    onPeek: { session in
                                        try await sessionManager.peekOutput(for: session)
                                    }
                                )
                                    .tag(session.id)
                            }
                        } header: {
                            SessionGroupHeader(
                                name: group.name,
                                count: group.sessions.count,
                                helpText: group.creationPath
                            )
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

        sessionManager.selectSession(id: visibleSessions[nextIndex].id)
    }

    private func selectVisibleSession(at index: Int) {
        guard visibleSessions.indices.contains(index) else {
            return
        }

        sessionManager.selectSession(id: visibleSessions[index].id)
    }
}

private struct SessionRowView: View {
    let session: SessionInfo
    var contextLabel: String?
    var contextHelp: String?
    var onSelect: ((SessionInfo) -> Void)?
    var onHide: ((SessionInfo) -> Void)?
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
                        onHide?(session)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundColor(AppTheme.mutedText)
                    }
                    .buttonStyle(.plain)
                    .help("Hide session")
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
                if let contextLabel {
                    Text(contextLabel)
                        .help(contextHelp ?? contextLabel)
                }
                if let branch = session.branchName {
                    Text(branch)
                }
                Text(session.status.label)
                if session.activityAt != nil {
                    SessionActivityBadgeView(session: session)
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(AppTheme.mutedText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect?(session)
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

            Button("Hide") {
                onHide?(session)
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

private struct SessionActivityBadgeView: View {
    let session: SessionInfo

    var body: some View {
        Text(session.activityLabel)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .foregroundColor(.white.opacity(0.94))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(session.activityTint)
            .clipShape(Capsule())
            .help(session.activityHelpText)
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

private struct SessionGroupHeader: View {
    let name: String
    let count: Int
    var helpText: String?
    var onCreate: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .lineLimit(1)

            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(.white.opacity(0.92))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(AppTheme.elevatedBackground)
                .clipShape(Capsule())

            Spacer(minLength: 8)

            if let onCreate {
                Button("New") {
                    onCreate()
                }
                .buttonStyle(.bordered)
                .controlSize(.mini)
            }
        }
        .help(helpText ?? name)
    }
}

private struct SessionDetailView: View {
    let session: SessionInfo?
    let lastRefresh: Date?
    @ObservedObject var terminalState: TmuxTerminalState
    let onOpenHelp: () -> Void
    let onRefresh: () -> Void
    var onRename: ((SessionInfo, String) async throws -> Void)?
    var onKill: ((SessionInfo) -> Void)?
    @State private var renameSheetPresented = false
    @State private var renameDraft = ""
    @State private var renameError: String?
    @State private var renameInFlight = false
    @State private var killConfirmationPresented = false

    var body: some View {
        ZStack {
            AppTheme.windowBackground
                .ignoresSafeArea()

            if let session {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .center, spacing: 12) {
                                Text(session.name)
                                    .font(.system(size: 18, weight: .bold, design: .rounded))

                                MetadataChip(text: session.status.label, tint: session.status.color)
                                if session.activityAt != nil {
                                    MetadataChip(text: session.activityLabel, tint: session.activityTint)
                                }
                                MetadataChip(text: session.process)
                                if let branch = session.branchName {
                                    MetadataChip(text: branch)
                                }
                            }

                            Text(terminalState.currentDirectory ?? session.shortenedWorkingDirectory)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundColor(AppTheme.mutedText)
                                .lineLimit(1)
                        }

                        Spacer()

                        HStack(spacing: 10) {
                            Button {
                                presentRenameSheet(for: session)
                            } label: {
                                Label("Rename", systemImage: "pencil")
                            }
                            .buttonStyle(.bordered)

                            Button(role: .destructive) {
                                killConfirmationPresented = true
                            } label: {
                                Label("Kill Session", systemImage: "xmark.circle")
                            }
                            .buttonStyle(.bordered)
                            .tint(.red)
                        }
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
        .sheet(isPresented: $renameSheetPresented) {
            if let session {
                RenameSessionSheetView(
                    currentName: session.name,
                    draftName: $renameDraft,
                    errorMessage: renameError,
                    isSubmitting: renameInFlight,
                    onCancel: {
                        guard !renameInFlight else {
                            return
                        }

                        renameSheetPresented = false
                    },
                    onSubmit: {
                        submitRename(for: session)
                    }
                )
            }
        }
        .alert("Sure?", isPresented: $killConfirmationPresented, presenting: session) { session in
            Button("Kill Session", role: .destructive) {
                onKill?(session)
            }

            Button("Cancel", role: .cancel) {}
        } message: { session in
            Text("This will terminate the tmux session named \(session.name).")
        }
    }

    private func presentRenameSheet(for session: SessionInfo) {
        renameDraft = session.name
        renameError = nil
        renameInFlight = false
        renameSheetPresented = true
    }

    private func submitRename(for session: SessionInfo) {
        let trimmedName = renameDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            renameError = "Session name cannot be empty."
            return
        }

        guard trimmedName != session.name else {
            renameSheetPresented = false
            return
        }

        renameError = nil
        renameInFlight = true

        Task {
            do {
                try await onRename?(session, trimmedName)
                await MainActor.run {
                    renameInFlight = false
                    renameSheetPresented = false
                }
            } catch {
                await MainActor.run {
                    renameInFlight = false
                    renameError = error.localizedDescription
                }
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

private struct RenameSessionSheetView: View {
    let currentName: String
    @Binding var draftName: String
    let errorMessage: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var nameFieldFocused: Bool

    private var trimmedDraftName: String {
        draftName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Rename Session")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            Text("Current name: \(currentName)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(AppTheme.mutedText)

            TextField("Session name", text: $draftName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .focused($nameFieldFocused)
                .onSubmit {
                    if !isRenameDisabled {
                        onSubmit()
                    }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button("Rename") {
                    onSubmit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isRenameDisabled)
            }
        }
        .padding(20)
        .frame(width: 420)
        .background(AppTheme.panelBackground)
        .onAppear {
            nameFieldFocused = true
        }
    }

    private var isRenameDisabled: Bool {
        isSubmitting || trimmedDraftName.isEmpty || trimmedDraftName == currentName
    }
}

private struct NewSessionSheetView: View {
    @Binding var directory: String
    let errorMessage: String?
    let isSubmitting: Bool
    let onCancel: () -> Void
    let onSubmit: () -> Void
    @FocusState private var directoryFieldFocused: Bool

    private var trimmedDirectory: String {
        directory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Session")
                .font(.system(size: 17, weight: .bold, design: .rounded))

            Text("Enter the repo or folder path to open with `tp new -c`.")
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundColor(AppTheme.mutedText)

            TextField("Repo or folder path", text: $directory)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, weight: .medium, design: .monospaced))
                .focused($directoryFieldFocused)
                .onSubmit {
                    if !isCreateDisabled {
                        onSubmit()
                    }
                }

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.red.opacity(0.9))
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()

                Button("Cancel") {
                    onCancel()
                }
                .keyboardShortcut(.cancelAction)
                .disabled(isSubmitting)

                Button("New") {
                    onSubmit()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isCreateDisabled)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(AppTheme.panelBackground)
        .onAppear {
            directoryFieldFocused = true
        }
    }

    private var isCreateDisabled: Bool {
        isSubmitting || trimmedDirectory.isEmpty
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
