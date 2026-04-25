import Foundation

public enum SessionStatus: String, Codable, CaseIterable, Hashable, Sendable {
    case active
    case idle
    case done
    case waitingHuman = "waiting-human"
    case unknown

    public init(rawStatus: String?) {
        guard let rawStatus else {
            self = .unknown
            return
        }

        self = SessionStatus(rawValue: rawStatus) ?? .unknown
    }

    public var label: String {
        switch self {
        case .active:
            return "Active"
        case .idle:
            return "Idle"
        case .done:
            return "Done"
        case .waitingHuman:
            return "Waiting Human"
        case .unknown:
            return "Unknown"
        }
    }

    public var rank: Int {
        switch self {
        case .active:
            return 0
        case .waitingHuman:
            return 1
        case .idle:
            return 2
        case .done:
            return 3
        case .unknown:
            return 4
        }
    }
}

public struct SessionInfo: Identifiable, Codable, Hashable, Sendable {
    public struct Metadata: Codable, Hashable, Sendable {
        public var repo: String?
        public let task: String?
        public let branch: String?
        public let desc: String?
        public let status: String?

        public init(
            repo: String? = nil,
            task: String? = nil,
            branch: String? = nil,
            desc: String? = nil,
            status: String? = nil
        ) {
            self.repo = repo
            self.task = task
            self.branch = branch
            self.desc = desc
            self.status = status
        }
    }

    public let name: String
    public let process: String
    public let workingDirectory: String
    public var metadata: Metadata

    public init(name: String, process: String, workingDirectory: String, metadata: Metadata) {
        self.name = name
        self.process = process
        self.workingDirectory = workingDirectory
        self.metadata = metadata
    }

    enum CodingKeys: String, CodingKey {
        case name
        case process
        case workingDirectory = "working_dir"
        case metadata
    }

    public var id: String { name }

    public var repoName: String {
        guard let candidate = metadata.repo?.nonEmpty else {
            // No @repo metadata — infer from working directory.
            // For worktrees (~/worktrees/*), resolve the parent repo name
            // by checking if the path contains "/worktrees/".
            let dir = workingDirectory
                .replacingOccurrences(of: "~", with: NSHomeDirectory())

            if dir.contains("/worktrees/") {
                // Worktree dir names are like "dismech-prev-1" or "agr-mouse-frmpd2".
                // The repo name is the prefix before the first dash-separated task portion.
                // Better: check if a git remote origin exists, but that's expensive.
                // Heuristic: use the session name prefix before the first hyphen,
                // or fall back to last path component.
            }

            return URL(fileURLWithPath: workingDirectory).lastPathComponent.nonEmpty ?? "Ungrouped"
        }

        if candidate.contains("/") {
            return URL(fileURLWithPath: candidate).lastPathComponent.nonEmpty ?? candidate
        }

        return candidate
    }

    public var repoGroupName: String {
        if let repo = repoName.nonEmpty {
            return repo
        }

        let dir = workingDirectory
            .replacingOccurrences(of: "~", with: NSHomeDirectory())
        let url = URL(fileURLWithPath: dir)

        // ~/repos/<repo-name> → use repo-name
        if url.deletingLastPathComponent().lastPathComponent == "repos" {
            return url.lastPathComponent
        }

        // For worktrees and everything else, fall back to last path component
        return url.lastPathComponent.nonEmpty ?? "Ungrouped"
    }

    public var status: SessionStatus {
        SessionStatus(rawStatus: metadata.status)
    }

    public var detailSummary: String {
        metadata.desc?.nonEmpty ?? metadata.task?.nonEmpty ?? shortenedWorkingDirectory
    }

    public var branchName: String? {
        metadata.branch?.nonEmpty
    }

    public var descriptionText: String? {
        metadata.desc?.nonEmpty
    }

    public var taskName: String? {
        metadata.task?.nonEmpty
    }

    public var shortenedWorkingDirectory: String {
        let path = workingDirectory
        let homePath = NSHomeDirectory()

        guard path.hasPrefix(homePath) else {
            return path
        }

        return "~" + path.dropFirst(homePath.count)
    }

    public var searchTokens: [String] {
        [
            name,
            repoGroupName,
            process,
            metadata.task,
            metadata.branch,
            metadata.desc,
            workingDirectory
        ]
        .compactMap { $0?.lowercased() }
    }

    public static func sort(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.repoGroupName.localizedCaseInsensitiveCompare(rhs.repoGroupName) != .orderedSame {
            return lhs.repoGroupName.localizedCaseInsensitiveCompare(rhs.repoGroupName) == .orderedAscending
        }

        if lhs.status.rank != rhs.status.rank {
            return lhs.status.rank < rhs.status.rank
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }
}

public struct SessionRepoGroup: Identifiable, Hashable, Sendable {
    public let name: String
    public let sessions: [SessionInfo]

    public init(name: String, sessions: [SessionInfo]) {
        self.name = name
        self.sessions = sessions
    }

    public var id: String { name }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
