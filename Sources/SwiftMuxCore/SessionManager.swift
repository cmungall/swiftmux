import Foundation

@MainActor
public final class SessionManager: ObservableObject {
    @Published public private(set) var sessions: [SessionInfo] = []
    @Published public var selectedSessionID: SessionInfo.ID?
    @Published public var groupByRepo = true
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var pollError: String?

    private var pollingTask: Task<Void, Never>?

    public init() {}

    deinit {
        pollingTask?.cancel()
    }

    public var selectedSession: SessionInfo? {
        sessions.first(where: { $0.id == selectedSessionID })
    }

    /// Sessions ordered by recency: active first, then by status rank.
    public var sessionsByRecency: [SessionInfo] {
        sessions.sorted { lhs, rhs in
            if lhs.status != rhs.status {
                return lhs.status.rank < rhs.status.rank
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    public var sessionGroups: [SessionRepoGroup] {
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

    public func startPolling() {
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

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    public func killSession(_ session: SessionInfo) {
        Task.detached {
            try? SessionService.kill(name: session.name)
        }
        sessions.removeAll { $0.id == session.id }
        if selectedSessionID == session.id {
            selectedSessionID = sessions.first?.id
        }
    }

    public func peekOutput(for session: SessionInfo, lines: Int = 50) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            try SessionService.peek(name: session.name, lines: lines)
        }.value
    }

    public func refresh() async {
        do {
            let sessions = try await Task.detached(priority: .userInitiated) {
                try SessionService.loadSessions()
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
}
