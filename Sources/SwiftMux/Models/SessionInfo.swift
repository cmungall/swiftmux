import Foundation
import SwiftUI

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
        let repo: String?
        let task: String?
        let branch: String?
        let desc: String?
        let status: String?
    }

    let name: String
    let process: String
    let workingDirectory: String
    let metadata: Metadata

    enum CodingKeys: String, CodingKey {
        case name
        case process
        case workingDirectory = "working_dir"
        case metadata
    }

    var id: String { name }

    var repoName: String {
        guard let candidate = metadata.repo?.nonEmpty else {
            return URL(fileURLWithPath: workingDirectory).lastPathComponent.nonEmpty ?? "Ungrouped"
        }

        if candidate.contains("/") {
            return URL(fileURLWithPath: candidate).lastPathComponent.nonEmpty ?? candidate
        }

        return candidate
    }

    var repoGroupName: String {
        repoName.nonEmpty ?? "Ungrouped"
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
            process,
            metadata.task,
            metadata.branch,
            metadata.desc,
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
}

struct SessionRepoGroup: Identifiable, Hashable {
    let name: String
    let sessions: [SessionInfo]

    var id: String { name }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
