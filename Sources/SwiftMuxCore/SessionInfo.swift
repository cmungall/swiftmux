import Foundation

public enum SessionActivityBucket: Hashable, Sendable {
    case none
    case seconds
    case minutes
    case hours
    case days
    case weeks
    case months
    case years
}

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
        public let lastSend: String?
        public let pr: String?
        public let prState: String?
        public let prReview: String?
        public let prMergeState: String?
        public let lastRefresh: String?

        enum CodingKeys: String, CodingKey {
            case repo
            case task
            case branch
            case desc
            case status
            case lastSend = "last_send"
            case pr
            case prState = "pr_state"
            case prReview = "pr_review"
            case prMergeState = "pr_merge_state"
            case lastRefresh = "last_refresh"
        }
    }

    public let name: String
    public let process: String
    public let workingDirectory: String
    public var metadata: Metadata
    public var canonicalRepoRoot: String? = nil
    public var githubRepoSlug: String? = nil
    public var tmuxActivityAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case name
        case process
        case workingDirectory = "working_dir"
        case metadata
    }

    public var id: String { name }

    public var repoName: String {
        if let repoRootPath {
            return URL(fileURLWithPath: repoRootPath).lastPathComponent.nonEmpty ?? "Ungrouped"
        }

        guard let candidate = metadata.repo?.nonEmpty else {
            return folderGroupName
        }

        if candidate.contains("/") {
            return URL(fileURLWithPath: candidate).lastPathComponent.nonEmpty ?? candidate
        }

        return candidate
    }

    public var repoGroupName: String {
        repoName.nonEmpty ?? "Ungrouped"
    }

    public var repoGroupKey: String {
        repoRootPath ?? "repo:\(repoGroupName.lowercased())"
    }

    public var folderGroupName: String {
        let url = URL(fileURLWithPath: resolvedWorkingDirectory)
        if url.deletingLastPathComponent().lastPathComponent == "repos" {
            return url.lastPathComponent
        }
        return url.lastPathComponent.nonEmpty ?? "Ungrouped"
    }

    public var folderGroupKey: String {
        resolvedWorkingDirectory.nonEmpty ?? folderGroupName
    }

    public var resolvedWorkingDirectory: String {
        (workingDirectory as NSString).expandingTildeInPath
    }

    public var repoRootPath: String? {
        canonicalRepoRoot ?? metadataRepoPath
    }

    public var repoScopedLocationName: String {
        guard let repoRootPath else {
            return folderGroupName
        }

        let normalizedRepoRoot = URL(fileURLWithPath: repoRootPath).standardizedFileURL.path
        let normalizedWorkingDirectory = URL(fileURLWithPath: resolvedWorkingDirectory).standardizedFileURL.path
        if normalizedRepoRoot == normalizedWorkingDirectory {
            return "root"
        }

        return folderGroupName
    }

    public var preferredCreationPath: String {
        repoRootPath ?? resolvedWorkingDirectory
    }

    private var metadataRepoPath: String? {
        guard let candidate = metadata.repo?.nonEmpty else {
            return nil
        }

        let expanded = (candidate as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            return nil
        }

        return expanded
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

    public var lastSendAt: Date? {
        Self.parseISO8601Timestamp(metadata.lastSend)
    }

    public var pullRequestNumber: String? {
        metadata.pr?.nonEmpty
    }

    public var pullRequestState: String? {
        metadata.prState?.nonEmpty
    }

    public var pullRequestReview: String? {
        metadata.prReview?.nonEmpty
    }

    public var pullRequestMergeState: String? {
        metadata.prMergeState?.nonEmpty
    }

    public var pullRequestLastRefreshAt: Date? {
        Self.parseISO8601Timestamp(metadata.lastRefresh)
    }

    public var pullRequestSummary: String? {
        guard let pr = pullRequestNumber else {
            return nil
        }

        switch pullRequestState {
        case "MERGED":
            return "\(pr) M"
        case "CLOSED":
            return "\(pr) X"
        default:
            break
        }

        var codes: [String] = []

        switch pullRequestReview {
        case "APPROVED":
            codes.append("A")
        case "CHANGES_REQUESTED":
            codes.append("CR")
        case "REVIEW_REQUIRED":
            codes.append("RR")
        case "PENDING":
            codes.append("P")
        default:
            break
        }

        switch pullRequestMergeState {
        case "DIRTY":
            codes.append("D")
        case "BLOCKED":
            codes.append("B")
        case "CLEAN":
            codes.append("C")
        default:
            break
        }

        guard !codes.isEmpty else {
            return pr
        }

        return "\(pr) \(codes.joined(separator: " "))"
    }

    public var pullRequestURL: URL? {
        guard let pr = pullRequestNumber,
              let repoSlug = githubRepoSlug?.nonEmpty else {
            return nil
        }

        return URL(string: "https://github.com/\(repoSlug)/pull/\(pr)")
    }

    public var activityAt: Date? {
        tmuxActivityAt ?? lastSendAt
    }

    public var activityBucket: SessionActivityBucket {
        guard let activityAt else {
            return .none
        }

        let age = max(Date().timeIntervalSince(activityAt), 0)

        switch age {
        case ..<60:
            return .seconds
        case ..<3_600:
            return .minutes
        case ..<86_400:
            return .hours
        case ..<2_592_000:
            return .days
        case ..<31_557_600:
            return .weeks
        case ..<94_608_000:
            return .months
        default:
            return .years
        }
    }

    public var activityLabel: String {
        guard let activityAt else {
            return "?"
        }

        let age = max(Date().timeIntervalSince(activityAt), 0)
        switch activityBucket {
        case .none:
            return "?"
        case .seconds:
            return "\(max(Int(age.rounded(.down)), 1))s"
        case .minutes:
            return "\(max(Int((age / 60).rounded(.down)), 1))m"
        case .hours:
            return "\(max(Int((age / 3_600).rounded(.down)), 1))h"
        case .days:
            return "\(max(Int((age / 86_400).rounded(.down)), 1))d"
        case .weeks:
            return "\(max(Int((age / 604_800).rounded(.down)), 1))w"
        case .months:
            return "\(max(Int((age / 2_592_000).rounded(.down)), 1))mo"
        case .years:
            return "\(max(Int((age / 31_557_600).rounded(.down)), 1))y"
        }
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
            folderGroupName,
            process,
            metadata.task,
            metadata.branch,
            metadata.desc,
            metadata.pr,
            metadata.prState,
            metadata.prReview,
            metadata.prMergeState,
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

    private static let iso8601Formatters: [ISO8601DateFormatter] = {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        return [fractional, plain]
    }()

    private static func parseISO8601Timestamp(_ value: String?) -> Date? {
        guard let timestamp = value?.nonEmpty else {
            return nil
        }

        return iso8601Formatters.lazy.compactMap { formatter in
            formatter.date(from: timestamp)
        }.first
    }
}

public struct SessionGroup: Identifiable, Hashable, Sendable {
    public let key: String
    public let name: String
    public let sessions: [SessionInfo]
    public let creationPath: String?

    public var id: String { key }
}

extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
