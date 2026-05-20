import Foundation
import SwiftUI

enum SessionActivityBucket: Hashable {
    case none
    case seconds
    case minutes
    case hours
    case days
    case weeks
    case months
    case years

    var tint: Color {
        switch self {
        case .none:
            return AppTheme.elevatedBackground
        case .seconds:
            return AppTheme.activeAccent
        case .minutes:
            return AppTheme.activeAccent.opacity(0.82)
        case .hours:
            return AppTheme.waitingAccent.opacity(0.78)
        case .days:
            return AppTheme.doneAccent.opacity(0.72)
        case .weeks:
            return AppTheme.idleAccent.opacity(0.82)
        case .months:
            return AppTheme.elevatedBackground.opacity(0.88)
        case .years:
            return AppTheme.elevatedBackground.opacity(0.95)
        }
    }
}

enum SessionStatus: String, Codable, CaseIterable, Hashable {
    case active
    case idle
    case done
    case waitingHuman = "waiting-human"
    case unknown

    init(rawStatus: String?) {
        guard let rawStatus else {
            self = .unknown
            return
        }

        self = SessionStatus(rawValue: rawStatus) ?? .unknown
    }

    var label: String {
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

    var color: Color {
        switch self {
        case .active:
            return AppTheme.activeAccent
        case .idle:
            return AppTheme.idleAccent
        case .done:
            return AppTheme.doneAccent
        case .waitingHuman:
            return AppTheme.waitingAccent
        case .unknown:
            return AppTheme.unknownAccent
        }
    }

    var rank: Int {
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

struct SessionInfo: Identifiable, Codable, Hashable {
    struct Metadata: Codable, Hashable {
        var repo: String?
        let task: String?
        let branch: String?
        let desc: String?
        let status: String?
        let lastSend: String?
        let pr: String?
        let prState: String?
        let prReview: String?
        let prMergeState: String?
        let lastRefresh: String?

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

    let name: String
    let process: String
    let workingDirectory: String
    var metadata: Metadata
    var canonicalRepoRoot: String? = nil
    var githubRepoSlug: String? = nil
    var tmuxActivityAt: Date? = nil

    enum CodingKeys: String, CodingKey {
        case name
        case process
        case workingDirectory = "working_dir"
        case metadata
    }

    var id: String { name }

    var repoName: String {
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

    var repoGroupName: String {
        repoName.nonEmpty ?? "Ungrouped"
    }

    var repoGroupKey: String {
        repoRootPath ?? "repo:\(repoGroupName.lowercased())"
    }

    var folderGroupName: String {
        let url = URL(fileURLWithPath: resolvedWorkingDirectory)

        // ~/repos/<repo-name> → use repo-name
        if url.deletingLastPathComponent().lastPathComponent == "repos" {
            return url.lastPathComponent
        }

        // For worktrees and everything else, fall back to last path component
        return url.lastPathComponent.nonEmpty ?? "Ungrouped"
    }

    var folderGroupKey: String {
        resolvedWorkingDirectory.nonEmpty ?? folderGroupName
    }

    var resolvedWorkingDirectory: String {
        (workingDirectory as NSString).expandingTildeInPath
    }

    var repoRootPath: String? {
        canonicalRepoRoot ?? metadataRepoPath
    }

    var repoScopedLocationName: String {
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

    var preferredCreationPath: String {
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

    var status: SessionStatus {
        SessionStatus(rawStatus: metadata.status)
    }

    var detailSummary: String {
        metadata.desc?.nonEmpty ?? metadata.task?.nonEmpty ?? shortenedWorkingDirectory
    }

    var branchName: String? {
        metadata.branch?.nonEmpty
    }

    var descriptionText: String? {
        metadata.desc?.nonEmpty
    }

    var taskName: String? {
        metadata.task?.nonEmpty
    }

    var lastSendAt: Date? {
        Self.parseISO8601Timestamp(metadata.lastSend)
    }

    var pullRequestNumber: String? {
        metadata.pr?.nonEmpty
    }

    var pullRequestState: String? {
        metadata.prState?.nonEmpty
    }

    var pullRequestReview: String? {
        metadata.prReview?.nonEmpty
    }

    var pullRequestMergeState: String? {
        metadata.prMergeState?.nonEmpty
    }

    var pullRequestLastRefreshAt: Date? {
        Self.parseISO8601Timestamp(metadata.lastRefresh)
    }

    var pullRequestSummary: String? {
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

    var pullRequestTint: Color {
        switch pullRequestState {
        case "MERGED":
            return AppTheme.doneAccent
        case "CLOSED":
            return AppTheme.unknownAccent
        default:
            break
        }

        if pullRequestReview == "CHANGES_REQUESTED"
            || pullRequestMergeState == "DIRTY"
            || pullRequestMergeState == "BLOCKED" {
            return AppTheme.waitingAccent
        }

        if pullRequestReview == "APPROVED" || pullRequestMergeState == "CLEAN" {
            return AppTheme.activeAccent
        }

        return AppTheme.idleAccent
    }

    var pullRequestURL: URL? {
        guard let pr = pullRequestNumber,
              let repoSlug = githubRepoSlug?.nonEmpty else {
            return nil
        }

        return URL(string: "https://github.com/\(repoSlug)/pull/\(pr)")
    }

    var shouldShowMergePullRequestAction: Bool {
        pullRequestState == "OPEN"
            && pullRequestReview == "APPROVED"
            && pullRequestNumber != nil
            && githubRepoSlug?.nonEmpty != nil
    }

    var canExecuteMergePullRequest: Bool {
        guard shouldShowMergePullRequestAction else {
            return false
        }

        switch pullRequestMergeState {
        case "DIRTY", "BLOCKED":
            return false
        default:
            return true
        }
    }

    var mergePullRequestHelpText: String {
        switch pullRequestMergeState {
        case "DIRTY":
            return "PR is approved but has merge conflicts."
        case "BLOCKED":
            return "PR is approved but blocked by repository rules or pending requirements."
        default:
            if let pr = pullRequestNumber {
                return "Merge PR #\(pr) on GitHub."
            }
            return "Merge approved PR."
        }
    }

    var pullRequestHelpText: String? {
        guard let pr = pullRequestNumber else {
            return nil
        }

        var parts = ["PR #\(pr)"]

        if let state = Self.displayLabel(forPullRequestState: pullRequestState) {
            parts.append(state)
        }
        if let review = Self.displayLabel(forPullRequestReview: pullRequestReview) {
            parts.append(review)
        }
        if let mergeState = Self.displayLabel(forPullRequestMergeState: pullRequestMergeState) {
            parts.append(mergeState)
        }
        if let lastRefreshAt = pullRequestLastRefreshAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .full
            parts.append("Updated \(formatter.localizedString(for: lastRefreshAt, relativeTo: Date()))")
        }

        if pullRequestURL != nil {
            parts.append("Click to open on GitHub.")
        }

        return parts.joined(separator: " · ")
    }

    var activityAt: Date? {
        tmuxActivityAt ?? lastSendAt
    }

    var activityBucket: SessionActivityBucket {
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

    var activityLabel: String {
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

    var activityTint: Color {
        activityBucket.tint
    }

    var activityHelpText: String {
        guard let activityAt else {
            return "No recorded recent activity."
        }

        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        let activitySummary = "Session activity \(formatter.localizedString(for: activityAt, relativeTo: Date()))."

        guard let lastSendAt, tmuxActivityAt != nil else {
            return activitySummary
        }

        let lastSendSummary = "Last send \(formatter.localizedString(for: lastSendAt, relativeTo: Date()))."
        return "\(activitySummary) \(lastSendSummary)"
    }

    var shortenedWorkingDirectory: String {
        let path = workingDirectory
        let homePath = NSHomeDirectory()

        guard path.hasPrefix(homePath) else {
            return path
        }

        return "~" + path.dropFirst(homePath.count)
    }

    var searchTokens: [String] {
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

    static func sort(_ lhs: SessionInfo, _ rhs: SessionInfo) -> Bool {
        if lhs.repoGroupName.localizedCaseInsensitiveCompare(rhs.repoGroupName) != .orderedSame {
            return lhs.repoGroupName.localizedCaseInsensitiveCompare(rhs.repoGroupName) == .orderedAscending
        }

        if lhs.status.rank != rhs.status.rank {
            return lhs.status.rank < rhs.status.rank
        }

        return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
    }

    private static func parseISO8601Timestamp(_ value: String?) -> Date? {
        guard let timestamp = value?.nonEmpty else {
            return nil
        }

        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = fractional.date(from: timestamp) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]

        return plain.date(from: timestamp)
    }

    private static func displayLabel(forPullRequestState value: String?) -> String? {
        switch value {
        case "OPEN":
            return "Open"
        case "CLOSED":
            return "Closed"
        case "MERGED":
            return "Merged"
        default:
            return value?.nonEmpty
        }
    }

    private static func displayLabel(forPullRequestReview value: String?) -> String? {
        switch value {
        case "APPROVED":
            return "Approved"
        case "CHANGES_REQUESTED":
            return "Changes Requested"
        case "REVIEW_REQUIRED":
            return "Review Required"
        case "PENDING":
            return "Pending Review"
        default:
            return value?.nonEmpty
        }
    }

    private static func displayLabel(forPullRequestMergeState value: String?) -> String? {
        switch value {
        case "DIRTY":
            return "Conflicted"
        case "BLOCKED":
            return "Blocked"
        case "CLEAN":
            return "Mergeable"
        case "UNSTABLE":
            return "Unstable"
        case "UNKNOWN":
            return nil
        default:
            return value?.nonEmpty
        }
    }
}

struct SessionGroup: Identifiable, Hashable {
    let key: String
    let name: String
    let sessions: [SessionInfo]
    let creationPath: String?

    var id: String { key }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
