import Foundation

enum SessionOrderingMode: String, CaseIterable, Hashable {
    case activity = "activity"
    case `default` = "default"

    var title: String {
        switch self {
        case .activity:
            return "Activity"
        case .default:
            return "Default"
        }
    }

    var shortLabel: String {
        switch self {
        case .activity:
            return "Activity"
        case .default:
            return "Default"
        }
    }
}

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published private(set) var selectedSessionID: SessionInfo.ID?
    @Published private(set) var hiddenSessionCount = 0
    @Published var groupByRepo = true
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var pollError: String?

    private var allSessions: [SessionInfo] = []
    private var hiddenSessionIDs: Set<SessionInfo.ID> = []
    private var pollingTask: Task<Void, Never>?

    deinit {
        pollingTask?.cancel()
    }

    var selectedSession: SessionInfo? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    func orderedSessions(using orderingMode: SessionOrderingMode) -> [SessionInfo] {
        sessions.sorted { lhs, rhs in
            compareSessions(lhs, rhs, orderingMode: orderingMode)
        }
    }

    func orderedRepoGroups(using orderingMode: SessionOrderingMode) -> [SessionGroup] {
        buildGroups(
            from: Dictionary(grouping: sessions, by: \.repoGroupKey),
            orderingMode: orderingMode,
            name: { sessions in
                sessions.first?.repoGroupName ?? "Ungrouped"
            },
            creationPath: { sessions in
                preferredRepoCreationPath(for: sessions)
            }
        )
    }

    func orderedFolderGroups(using orderingMode: SessionOrderingMode) -> [SessionGroup] {
        buildGroups(
            from: Dictionary(grouping: sessions, by: \.folderGroupKey),
            orderingMode: orderingMode,
            name: { sessions in
                sessions.first?.folderGroupName ?? "Ungrouped"
            },
            creationPath: { sessions in
                sessions.first?.resolvedWorkingDirectory
            }
        )
    }

    func selectSession(_ session: SessionInfo) {
        selectSession(id: session.id)
    }

    func selectSession(id: SessionInfo.ID?) {
        selectedSessionID = id
    }

    func startPolling() {
        guard pollingTask == nil else {
            return
        }

        pollingTask = Task { [weak self] in
            guard let self else {
                return
            }

            await self.refresh()

            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.refresh()
            }
        }
    }

    func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    func hideSession(_ session: SessionInfo) {
        hiddenSessionIDs.insert(session.id)
        applyVisibleSessions(preferredSelectionID: selectedSessionID)
    }

    func unhideAllSessions() {
        guard !hiddenSessionIDs.isEmpty else {
            return
        }

        hiddenSessionIDs.removeAll()
        applyVisibleSessions(preferredSelectionID: selectedSessionID)
    }

    func killSession(_ session: SessionInfo) {
        hiddenSessionIDs.remove(session.id)
        allSessions.removeAll { $0.id == session.id }
        applyVisibleSessions(preferredSelectionID: selectedSessionID)

        Task.detached {
            _ = try? CommandRunner.run(
                executable: "/usr/bin/env",
                arguments: ["tp", "kill", session.name]
            )
        }
    }

    func renameSession(_ session: SessionInfo, to proposedName: String) async throws {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else {
            throw CommandRunnerError.executionFailed("Session name cannot be empty.")
        }

        guard trimmedName != session.name else {
            return
        }

        _ = try await Task.detached(priority: .userInitiated) {
            try CommandRunner.runExpectingSuccess(
                executable: "/usr/bin/env",
                arguments: ["tmux", "rename-session", "-t", session.name, trimmedName]
            )
        }.value

        applyRename(from: session, to: trimmedName)
    }

    func peekOutput(for session: SessionInfo, lines: Int = 50) async throws -> String {
        return try await Task.detached(priority: .userInitiated) {
            let output = try CommandRunner.runExpectingSuccess(
                executable: "/usr/bin/env",
                arguments: ["tp", "peek", "--lines", String(lines), session.name]
            )
            return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        }.value
    }

    func createSession(in directory: String) async throws {
        let trimmedDirectory = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDirectory.isEmpty else {
            throw CommandRunnerError.executionFailed("Repo or folder path cannot be empty.")
        }

        let resolvedDirectory = (trimmedDirectory as NSString).expandingTildeInPath
        let createdSessionName = try await Task.detached(priority: .userInitiated) {
            try Self.createSessionWithResolvedDirectory(resolvedDirectory)
        }.value

        await refresh()

        if sessions.contains(where: { $0.id == createdSessionName }) {
            selectSession(id: createdSessionName)
        }
    }

    func refresh() async {
        do {
            let loadedSessions = try await Task.detached(priority: .userInitiated) {
                try Self.loadSessions()
            }.value

            let selectedSessionID = self.selectedSessionID

            self.allSessions = loadedSessions
            self.hiddenSessionIDs.formIntersection(Set(loadedSessions.map(\.id)))
            self.applyVisibleSessions(preferredSelectionID: selectedSessionID)
            self.lastRefresh = Date()
            self.pollError = nil
        } catch {
            pollError = error.localizedDescription
        }
    }

    nonisolated private static func resolveGitRepoName(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let result = try? CommandRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "remote", "get-url", "origin"]
        )
        guard let url = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }
        // Extract repo name from URL like:
        //   git@github.com:org/repo.git → repo
        //   https://github.com/org/repo.git → repo
        var name = URL(fileURLWithPath: url.replacingOccurrences(of: ":", with: "/"))
            .deletingPathExtension().lastPathComponent
        if name.isEmpty {
            // Try splitting by / for SSH URLs
            name = url.split(separator: "/").last.map { String($0) }?
                .replacingOccurrences(of: ".git", with: "") ?? ""
        }
        return name.isEmpty ? nil : name
    }

    private var preferredSessionID: SessionInfo.ID? {
        orderedSessions(using: .activity).first?.id
    }

    private func applyVisibleSessions(preferredSelectionID: SessionInfo.ID?) {
        sessions = allSessions.filter { !hiddenSessionIDs.contains($0.id) }
        hiddenSessionCount = hiddenSessionIDs.count

        if let preferredSelectionID, sessions.contains(where: { $0.id == preferredSelectionID }) {
            selectedSessionID = preferredSelectionID
        } else {
            selectedSessionID = self.preferredSessionID
        }
    }

    private func applyRename(from session: SessionInfo, to newName: String) {
        let renamedSession = SessionInfo(
            name: newName,
            process: session.process,
            workingDirectory: session.workingDirectory,
            metadata: session.metadata,
            canonicalRepoRoot: session.canonicalRepoRoot,
            tmuxActivityAt: session.tmuxActivityAt
        )

        if let index = allSessions.firstIndex(where: { $0.id == session.id }) {
            allSessions[index] = renamedSession
        }

        let wasHidden = hiddenSessionIDs.remove(session.id) != nil
        if wasHidden {
            hiddenSessionIDs.insert(renamedSession.id)
        }

        let preferredSelectionID = selectedSessionID == session.id ? renamedSession.id : selectedSessionID
        applyVisibleSessions(preferredSelectionID: preferredSelectionID)
    }

    private func compareSessions(
        _ lhs: SessionInfo,
        _ rhs: SessionInfo,
        orderingMode: SessionOrderingMode
    ) -> Bool {
        if orderingMode == .activity {
            let lhsDate = lhs.activityAt
            let rhsDate = rhs.activityAt
            if lhsDate != rhsDate {
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }

            let lhsLastSend = lhs.lastSendAt
            let rhsLastSend = rhs.lastSendAt
            if lhsLastSend != rhsLastSend {
                return (lhsLastSend ?? .distantPast) > (rhsLastSend ?? .distantPast)
            }
        }

        return SessionInfo.sort(lhs, rhs)
    }

    private func compareGroups(
        _ lhs: SessionGroup,
        _ rhs: SessionGroup,
        orderingMode: SessionOrderingMode
    ) -> Bool {
        if orderingMode == .activity {
            let lhsDate = groupActivityDate(for: lhs.sessions)
            let rhsDate = groupActivityDate(for: rhs.sessions)
            if lhsDate != rhsDate {
                return (lhsDate ?? .distantPast) > (rhsDate ?? .distantPast)
            }
        }

        if lhs.name == "Ungrouped" { return false }
        if rhs.name == "Ungrouped" { return true }
        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private func groupActivityDate(for sessions: [SessionInfo]) -> Date? {
        sessions
            .compactMap(\.activityAt)
            .max()
    }

    private func buildGroups(
        from groupedSessions: [String: [SessionInfo]],
        orderingMode: SessionOrderingMode,
        name: ([SessionInfo]) -> String,
        creationPath: ([SessionInfo]) -> String?
    ) -> [SessionGroup] {
        groupedSessions
            .map { key, sessions in
                let sortedSessions = sessions.sorted { lhs, rhs in
                    compareSessions(lhs, rhs, orderingMode: orderingMode)
                }

                return SessionGroup(
                    key: key,
                    name: name(sortedSessions),
                    sessions: sortedSessions,
                    creationPath: creationPath(sortedSessions)
                )
            }
            .sorted { lhs, rhs in
                compareGroups(lhs, rhs, orderingMode: orderingMode)
            }
    }

    private func preferredRepoCreationPath(for sessions: [SessionInfo]) -> String? {
        sessions
            .compactMap(\.repoRootPath)
            .first ?? sessions.first?.resolvedWorkingDirectory
    }

    nonisolated private static func createdSessionName(from output: String) -> String? {
        let prefix = "Created session '"

        for line in output.split(whereSeparator: \.isNewline).reversed() {
            guard let start = line.range(of: prefix)?.upperBound else {
                continue
            }

            let suffix = line[start...]
            guard let end = suffix.firstIndex(of: "'") else {
                continue
            }

            return String(suffix[..<end])
        }

        return nil
    }

    nonisolated private static func createSessionWithResolvedDirectory(_ directory: String) throws -> String {
        let baseName = try inferSessionName(for: directory)
        var attemptedNames: Set<String> = []

        for _ in 0..<8 {
            let existingNames = try currentTmuxSessionNames()
            let candidateName = uniqueSessionName(base: baseName, existing: existingNames.union(attemptedNames))

            do {
                let output = try CommandRunner.runExpectingSuccess(
                    executable: "/usr/bin/env",
                    arguments: ["tp", "new", candidateName, "-c", directory]
                )
                return createdSessionName(from: output.stdout) ?? candidateName
            } catch {
                attemptedNames.insert(candidateName)

                // Retry if the inferred name raced with another creator or tp/tmux disagreed
                // about whether the session already existed.
                if existingNames.contains(candidateName) || tmuxSessionExists(named: candidateName) {
                    continue
                }

                throw error
            }
        }

        throw CommandRunnerError.executionFailed("Failed to create a unique tmux session name for \(directory).")
    }

    nonisolated private static func inferSessionName(for directory: String) throws -> String {
        let resolvedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let canonicalRepoRoot = resolveCanonicalRepoRoot(at: resolvedDirectory)
        let sourcePath = canonicalRepoRoot ?? resolvedDirectory
        let rawName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let sanitized = rawName
            .replacingOccurrences(
                of: #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard !sanitized.isEmpty else {
            throw CommandRunnerError.executionFailed("Could not infer a session name from \(directory).")
        }

        return sanitized
    }

    nonisolated private static func uniqueSessionName(base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else {
            return base
        }

        var suffix = 1
        while existing.contains("\(base)-\(suffix)") {
            suffix += 1
        }

        return "\(base)-\(suffix)"
    }

    nonisolated private static func currentTmuxSessionNames() throws -> Set<String> {
        let output = try CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["tmux", "list-sessions", "-F", "#S"]
        )

        guard output.exitCode == 0 else {
            let message = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CommandRunnerError.executionFailed(
                message.isEmpty ? "Failed to list tmux sessions." : message
            )
        }

        return Set(
            output.stdout
                .split(whereSeparator: \.isNewline)
                .map(String.init)
                .filter { !$0.isEmpty }
        )
    }

    nonisolated private static func tmuxSessionExists(named name: String) -> Bool {
        guard let output = try? CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["tmux", "has-session", "-t", name]
        ) else {
            return false
        }

        return output.exitCode == 0
    }

    nonisolated private static func loadSessions() throws -> [SessionInfo] {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "ls", "--json"]
        )

        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        var decoded = try decoder.decode([SessionInfo].self, from: data)
        let activityByName = (try? Self.loadTmuxSessionActivity()) ?? [:]

        // Enrich sessions that lack @repo metadata by resolving git remote
        for i in decoded.indices {
            decoded[i].tmuxActivityAt = activityByName[decoded[i].name]
            let dir = decoded[i].workingDirectory
                .replacingOccurrences(of: "~", with: NSHomeDirectory())
            decoded[i].canonicalRepoRoot = Self.resolveCanonicalRepoRoot(at: dir)

            if decoded[i].metadata.repo == nil || decoded[i].metadata.repo?.isEmpty == true {
                if let repoRoot = decoded[i].canonicalRepoRoot {
                    decoded[i].metadata.repo = repoRoot
                } else if let repoName = Self.resolveGitRepoName(at: dir) {
                    decoded[i].metadata.repo = repoName
                }
            }
        }

        return decoded.sorted(by: SessionInfo.sort)
    }

    nonisolated private static func loadTmuxSessionActivity() throws -> [String: Date] {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tmux", "list-sessions", "-F", "#S\t#{session_activity}"]
        )

        var activityByName: [String: Date] = [:]
        for line in output.stdout.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2,
                  let seconds = TimeInterval(parts[1]),
                  seconds > 0 else {
                continue
            }

            activityByName[parts[0]] = Date(timeIntervalSince1970: seconds)
        }

        return activityByName
    }

    nonisolated private static func resolveCanonicalRepoRoot(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let commonDirResult = try? CommandRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "rev-parse", "--git-common-dir"]
        )
        guard commonDirResult?.exitCode == 0,
              let commonDir = {
                  let trimmed = commonDirResult?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                  return trimmed.isEmpty ? nil : trimmed
              }() else {
            return nil
        }

        let resolvedCommonDir: String
        if commonDir.hasPrefix("/") {
            resolvedCommonDir = commonDir
        } else {
            resolvedCommonDir = URL(fileURLWithPath: path)
                .appendingPathComponent(commonDir)
                .standardizedFileURL
                .path
        }

        let commonDirURL = URL(fileURLWithPath: resolvedCommonDir).standardizedFileURL
        if commonDirURL.lastPathComponent == ".git" {
            return commonDirURL.deletingLastPathComponent().path
        }

        let topLevelResult = try? CommandRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "rev-parse", "--show-toplevel"]
        )
        guard topLevelResult?.exitCode == 0 else {
            return nil
        }

        let topLevel = topLevelResult?.stdout
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return topLevel.isEmpty ? nil : topLevel
    }
}
