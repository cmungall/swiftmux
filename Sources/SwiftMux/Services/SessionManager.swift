import Foundation

private let sessionRefreshIntervalNanoseconds: UInt64 = 10_000_000_000

struct SessionCreationRequest {
    let repoPath: String
    let profile: SessionCreationProfile
    let issueNumber: Int?
    let description: String?
    let isBossSession: Bool
}

enum SessionCreationProfile: String, CaseIterable, Identifiable, Hashable {
    case codex
    case claude
    case pi

    var id: String { rawValue }

    var title: String {
        switch self {
        case .codex:
            return "Codex"
        case .claude:
            return "Claude"
        case .pi:
            return "Pi"
        }
    }

    var commandSummary: String {
        switch self {
        case .codex:
            return "codex --profile yolo"
        case .claude:
            return "claude --permission-mode bypassPermissions"
        case .pi:
            return "pi --offline"
        }
    }
}

private enum PullRequestMergeStrategy: String, Decodable {
    case merge = "MERGE"
    case rebase = "REBASE"
    case squash = "SQUASH"

    var flag: String {
        switch self {
        case .merge:
            return "--merge"
        case .rebase:
            return "--rebase"
        case .squash:
            return "--squash"
        }
    }
}

private struct RepoMergeConfiguration: Decodable {
    let viewerDefaultMergeMethod: PullRequestMergeStrategy?
    let mergeCommitAllowed: Bool
    let rebaseMergeAllowed: Bool
    let squashMergeAllowed: Bool

    var preferredStrategy: PullRequestMergeStrategy? {
        if let viewerDefaultMergeMethod, isAllowed(viewerDefaultMergeMethod) {
            return viewerDefaultMergeMethod
        }

        if mergeCommitAllowed {
            return .merge
        }

        if squashMergeAllowed {
            return .squash
        }

        if rebaseMergeAllowed {
            return .rebase
        }

        return nil
    }

    private func isAllowed(_ strategy: PullRequestMergeStrategy) -> Bool {
        switch strategy {
        case .merge:
            return mergeCommitAllowed
        case .rebase:
            return rebaseMergeAllowed
        case .squash:
            return squashMergeAllowed
        }
    }
}

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
                try? await Task.sleep(nanoseconds: sessionRefreshIntervalNanoseconds)
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

    func createSession(using request: SessionCreationRequest) async throws {
        let trimmedRepoPath = request.repoPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRepoPath.isEmpty else {
            throw CommandRunnerError.executionFailed("Repo path cannot be empty.")
        }

        let resolvedRepoPath = (trimmedRepoPath as NSString).expandingTildeInPath
        let createdSessionName = try await Task.detached(priority: .userInitiated) {
            try Self.createSession(using: request, resolvedRepoPath: resolvedRepoPath)
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

    func refreshPullRequestMetadata(for sessionNames: [String]? = nil) async {
        do {
            try await Task.detached(priority: .userInitiated) {
                try Self.runPullRequestRefresh(sessionNames: sessionNames)
            }.value

            await refresh()
        } catch {
            pollError = error.localizedDescription
        }
    }

    func mergePullRequest(for session: SessionInfo) async throws {
        guard let pullRequestNumber = session.pullRequestNumber else {
            throw CommandRunnerError.executionFailed("No pull request is associated with this session.")
        }

        guard let repoSlug = session.githubRepoSlug,
              !repoSlug.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CommandRunnerError.executionFailed("Could not resolve the GitHub repository for this session.")
        }

        try await Task.detached(priority: .userInitiated) {
            try Self.mergePullRequest(number: pullRequestNumber, repoSlug: repoSlug)
            try Self.runPullRequestRefresh(sessionNames: [session.name])
        }.value

        await refresh()
    }

    func runReap(dryRun: Bool) async throws -> String {
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runReap(dryRun: dryRun)
        }.value

        if !dryRun {
            await refresh()
        }

        return Self.combinedOutput(from: output)
    }

    func runProd(for session: SessionInfo) async throws -> String {
        let output = try await Task.detached(priority: .userInitiated) {
            try Self.runProd(sessionName: session.name)
        }.value

        await refresh()

        return Self.combinedOutput(from: output)
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
            githubRepoSlug: session.githubRepoSlug,
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

    nonisolated private static func createSession(
        using request: SessionCreationRequest,
        resolvedRepoPath: String
    ) throws -> String {
        let baseName = try baseSessionName(for: request, repoPath: resolvedRepoPath)
        let existingNames = try currentTmuxSessionNames()
        let candidateName = uniqueSessionName(base: baseName, existing: existingNames)

        var arguments = ["tp", "new", candidateName, "--profile", request.profile.rawValue]
        if request.isBossSession {
            arguments += ["-c", resolvedRepoPath]
        } else {
            arguments += ["--repo", resolvedRepoPath]
        }

        if let issueNumber = request.issueNumber {
            arguments += ["--issue", String(issueNumber)]
        }

        if let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            arguments += ["-d", description]
        }

        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: arguments
        )

        return createdSessionName(from: output.stdout) ?? candidateName
    }

    nonisolated private static func baseSessionName(
        for request: SessionCreationRequest,
        repoPath: String
    ) throws -> String {
        if request.isBossSession {
            let repoName = URL(fileURLWithPath: repoPath).lastPathComponent
            let bossName = sanitizeSessionName("\(repoName)-boss", lowercased: true)
            guard !bossName.isEmpty else {
                throw CommandRunnerError.executionFailed("Could not infer a boss session name from \(repoPath).")
            }
            return bossName
        }

        if let description = request.description?.trimmingCharacters(in: .whitespacesAndNewlines),
           !description.isEmpty {
            let sanitized = sanitizeSessionName(description, lowercased: true)
            guard !sanitized.isEmpty else {
                throw CommandRunnerError.executionFailed("Could not infer a session name from the task description.")
            }
            return sanitized
        }

        if let issueNumber = request.issueNumber {
            return "issue-\(issueNumber)"
        }

        throw CommandRunnerError.executionFailed("Provide an issue number or task description.")
    }

    nonisolated private static func inferSessionName(for directory: String) throws -> String {
        let resolvedDirectory = URL(fileURLWithPath: directory).standardizedFileURL.path
        let canonicalRepoRoot = resolveCanonicalRepoRoot(at: resolvedDirectory)
        let sourcePath = canonicalRepoRoot ?? resolvedDirectory
        let rawName = URL(fileURLWithPath: sourcePath).lastPathComponent
        let sanitized = sanitizeSessionName(rawName)

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

    nonisolated private static func sanitizeSessionName(
        _ rawName: String,
        lowercased: Bool = false
    ) -> String {
        let source = lowercased ? rawName.lowercased() : rawName
        let sanitized = source
            .replacingOccurrences(
                of: lowercased ? #"[^a-z0-9._-]+"# : #"[^A-Za-z0-9._-]+"#,
                with: "-",
                options: .regularExpression
            )
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))

        guard sanitized.count > 48 else {
            return sanitized
        }

        return String(sanitized.prefix(48)).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
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
            let repoPath = decoded[i].canonicalRepoRoot ?? dir
            decoded[i].githubRepoSlug = Self.resolveGitHubRepoSlug(at: repoPath)

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

    nonisolated private static func runPullRequestRefresh(sessionNames: [String]?) throws {
        let names = sessionNames?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        _ = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "refresh"] + (names ?? [])
        )
    }

    nonisolated private static func runReap(dryRun: Bool) throws -> CommandOutput {
        try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: reapCommandArguments(dryRun: dryRun)
        )
    }

    nonisolated private static func runProd(sessionName: String) throws -> CommandOutput {
        let output = try CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: prodCommandArguments(sessionName: sessionName)
        )

        if output.exitCode == 0 {
            return output
        }

        if isUnknownSubcommandError(output: output, command: "prod") {
            throw CommandRunnerError.executionFailed(
                "The installed tp does not support `tp prod` yet. Upgrade tmux-pilot to a version that includes the prod command."
            )
        }

        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        throw CommandRunnerError.executionFailed(
            stderr.isEmpty ? "tp prod failed." : stderr
        )
    }

    nonisolated private static func mergePullRequest(number: String, repoSlug: String) throws {
        do {
            try runGitHubPullRequestMerge(number: number, repoSlug: repoSlug, strategy: nil)
        } catch let error as CommandRunnerError {
            guard errorRequiresExplicitMergeStrategy(error) else {
                throw error
            }

            guard let strategy = try preferredMergeStrategy(for: repoSlug) else {
                throw CommandRunnerError.executionFailed(
                    "GitHub requires an explicit merge strategy for this repository, but SwiftMux could not determine whether merge, squash, or rebase is allowed."
                )
            }

            try runGitHubPullRequestMerge(number: number, repoSlug: repoSlug, strategy: strategy)
        }
    }

    nonisolated private static func runGitHubPullRequestMerge(
        number: String,
        repoSlug: String,
        strategy: PullRequestMergeStrategy?
    ) throws {
        var arguments = ["gh", "pr", "merge", number, "--repo", repoSlug, "--auto"]
        if let strategy {
            arguments.append(strategy.flag)
        }

        _ = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: arguments
        )
    }

    nonisolated private static func preferredMergeStrategy(for repoSlug: String) throws -> PullRequestMergeStrategy? {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: [
                "gh", "repo", "view", repoSlug,
                "--json", "viewerDefaultMergeMethod,mergeCommitAllowed,rebaseMergeAllowed,squashMergeAllowed"
            ]
        )

        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        let configuration = try decoder.decode(RepoMergeConfiguration.self, from: data)
        return configuration.preferredStrategy
    }

    nonisolated private static func errorRequiresExplicitMergeStrategy(_ error: CommandRunnerError) -> Bool {
        guard case .executionFailed(let message) = error else {
            return false
        }

        let lowered = message.lowercased()
        return lowered.contains("--merge")
            && lowered.contains("--rebase")
            && lowered.contains("--squash")
            && lowered.contains("required")
    }

    nonisolated private static func reapCommandArguments(dryRun: Bool) -> [String] {
        var arguments = ["tp", "reap"]
        if dryRun {
            arguments.append("--dry-run")
        } else {
            arguments.append("--force")
        }
        return arguments
    }

    nonisolated private static func prodCommandArguments(sessionName: String) -> [String] {
        var arguments = ["tp", "prod"]
        arguments.append(sessionName)
        return arguments
    }

    nonisolated private static func isUnknownSubcommandError(output: CommandOutput, command: String) -> Bool {
        let stderr = output.stderr.lowercased()
        return stderr.contains("invalid choice: '\(command)'")
            || stderr.contains("invalid choice: “\(command)”")
            || stderr.contains("unknown command")
    }

    nonisolated private static func combinedOutput(from output: CommandOutput) -> String {
        let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        return [stdout, stderr]
            .filter { !$0.isEmpty }
            .joined(separator: stdout.isEmpty || stderr.isEmpty ? "" : "\n\n")
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

    nonisolated private static func resolveGitHubRepoSlug(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }

        let result = try? CommandRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "remote", "get-url", "origin"]
        )
        guard result?.exitCode == 0 else {
            return nil
        }

        let remoteURL = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return parseGitHubRepoSlug(from: remoteURL)
    }

    nonisolated private static func parseGitHubRepoSlug(from remoteURL: String) -> String? {
        let trimmed = remoteURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let prefixes = [
            "https://github.com/",
            "http://github.com/",
            "ssh://git@github.com/",
            "git@github.com:",
            "github.com/"
        ]

        for prefix in prefixes where trimmed.hasPrefix(prefix) {
            return normalizeGitHubRepoSlug(String(trimmed.dropFirst(prefix.count)))
        }

        if let range = trimmed.range(of: "github.com/") {
            return normalizeGitHubRepoSlug(String(trimmed[range.upperBound...]))
        }

        return nil
    }

    nonisolated private static func normalizeGitHubRepoSlug(_ value: String) -> String? {
        let cleaned = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ".git", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = cleaned.split(separator: "/").map(String.init)
        guard parts.count >= 2 else {
            return nil
        }

        return "\(parts[0])/\(parts[1])"
    }
}
