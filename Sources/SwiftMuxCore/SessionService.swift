import Foundation

/// Stateless facade over the `tp` and `tmux` CLIs for server-side session access.
public enum SessionService {
    public static func loadSessions() throws -> [SessionInfo] {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "ls", "--json"]
        )

        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        var decoded = try decoder.decode([SessionInfo].self, from: data)
        let activityByName = (try? loadTmuxSessionActivity()) ?? [:]

        for i in decoded.indices {
            decoded[i].tmuxActivityAt = activityByName[decoded[i].name]
            let dir = decoded[i].workingDirectory
                .replacingOccurrences(of: "~", with: NSHomeDirectory())
            decoded[i].canonicalRepoRoot = resolveCanonicalRepoRoot(at: dir)
            let repoPath = decoded[i].canonicalRepoRoot ?? dir
            decoded[i].githubRepoSlug = resolveGitHubRepoSlug(at: repoPath)

            if decoded[i].metadata.repo == nil || decoded[i].metadata.repo?.isEmpty == true {
                if let repoRoot = decoded[i].canonicalRepoRoot {
                    decoded[i].metadata.repo = repoRoot
                } else if let repoName = resolveGitRepoName(at: dir) {
                    decoded[i].metadata.repo = repoName
                }
            }
        }

        return decoded.sorted(by: SessionInfo.sort)
    }

    public static func peek(name: String, lines: Int = 50) throws -> String {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "peek", "--lines", String(lines), name]
        )
        return output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func kill(name: String) throws {
        _ = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "kill", name]
        )
    }

    public static func resolveGitRepoName(at path: String) -> String? {
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let result = try? CommandRunner.run(
            executable: "/usr/bin/git",
            arguments: ["-C", path, "remote", "get-url", "origin"]
        )
        guard let url = result?.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
              !url.isEmpty else { return nil }

        var name = URL(fileURLWithPath: url.replacingOccurrences(of: ":", with: "/"))
            .deletingPathExtension().lastPathComponent
        if name.isEmpty {
            name = url.split(separator: "/").last.map { String($0) }?
                .replacingOccurrences(of: ".git", with: "") ?? ""
        }
        return name.isEmpty ? nil : name
    }

    private static func loadTmuxSessionActivity() throws -> [String: Date] {
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

    private static func resolveCanonicalRepoRoot(at path: String) -> String? {
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

    private static func resolveGitHubRepoSlug(at path: String) -> String? {
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

    private static func parseGitHubRepoSlug(from remoteURL: String) -> String? {
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

    private static func normalizeGitHubRepoSlug(_ value: String) -> String? {
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
