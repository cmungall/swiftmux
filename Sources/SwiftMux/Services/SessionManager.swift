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

    nonisolated private static func loadSessions() throws -> [SessionInfo] {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "ls", "--json"]
        )

        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode([SessionInfo].self, from: data)
        return decoded.sorted(by: SessionInfo.sort)
    }
}
