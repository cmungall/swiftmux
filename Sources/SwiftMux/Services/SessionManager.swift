import Foundation

@MainActor
final class SessionManager: ObservableObject {
    @Published private(set) var sessions: [SessionInfo] = []
    @Published var selectedSessionID: SessionInfo.ID?
    @Published var groupByRepo = true
    @Published private(set) var lastRefresh: Date?
    @Published private(set) var pollError: String?

    private var pollingTask: Task<Void, Never>?

    deinit {
        pollingTask?.cancel()
    }

    var selectedSession: SessionInfo? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    /// Sessions ordered by recency: active first, then by status rank.
    var sessionsByRecency: [SessionInfo] {
        sessions.sorted { lhs, rhs in
            // Active/running always first
            if lhs.status != rhs.status {
                return lhs.status.rank < rhs.status.rank
            }
            // Within same status, alphabetical by name
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    var sessionGroups: [SessionRepoGroup] {
        let grouped = Dictionary(grouping: sessions, by: \.repoGroupName)
        let names = grouped.keys.sorted { lhs, rhs in
            if lhs == "Ungrouped" { return false }
            if rhs == "Ungrouped" { return true }
            return lhs.localizedCaseInsensitiveCompare(rhs) == .orderedAscending
        }

        return names.compactMap { name in
            guard let sessions = grouped[name] else {
                return nil
            }

            return SessionRepoGroup(
                name: name,
                sessions: sessions.sorted(by: SessionInfo.sort)
            )
        }
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

    func killSession(_ session: SessionInfo) {
        Task.detached {
            _ = try? CommandRunner.run(
                executable: "/usr/bin/env",
                arguments: ["tp", "kill", session.name]
            )
        }
        // Remove from list immediately for snappy UI
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
    }

    func refresh() async {
        do {
            let sessions = try await Task.detached(priority: .userInitiated) {
                try Self.loadSessions()
            }.value

            let selectedSessionID = self.selectedSessionID

            self.sessions = sessions
            self.lastRefresh = Date()
            self.pollError = nil

            if let selectedSessionID, sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = selectedSessionID
            } else {
                self.selectedSessionID = sessions.first?.id
            }
        } catch {
            pollError = error.localizedDescription
        }
    }

    /// Resolve repo name from git remote origin URL at a directory.
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

    nonisolated private static func loadSessions() throws -> [SessionInfo] {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "ls", "--json"]
        )

        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        var decoded = try decoder.decode([SessionInfo].self, from: data)

        // Enrich sessions that lack @repo metadata by resolving git remote
        for i in decoded.indices {
            if decoded[i].metadata.repo == nil || decoded[i].metadata.repo?.isEmpty == true {
                let dir = decoded[i].workingDirectory
                    .replacingOccurrences(of: "~", with: NSHomeDirectory())
                if let repoName = Self.resolveGitRepoName(at: dir) {
                    decoded[i].metadata.repo = repoName
                }
            }
        }

        return decoded.sorted(by: SessionInfo.sort)
    }
}
