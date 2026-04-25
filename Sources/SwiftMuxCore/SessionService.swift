import Foundation

/// Stateless façade over the `tp` CLI used by both the macOS app and the server.
public enum SessionService {
    /// Load all tmux sessions, enriched with `@repo` metadata where missing
    /// by resolving git remote origin from the working directory.
    public static func loadSessions() throws -> [SessionInfo] {
        let output = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tp", "ls", "--json"]
        )

        let data = Data(output.stdout.utf8)
        let decoder = JSONDecoder()
        var decoded = try decoder.decode([SessionInfo].self, from: data)

        for i in decoded.indices {
            if decoded[i].metadata.repo == nil || decoded[i].metadata.repo?.isEmpty == true {
                let dir = decoded[i].workingDirectory
                    .replacingOccurrences(of: "~", with: NSHomeDirectory())
                if let repoName = resolveGitRepoName(at: dir) {
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

    /// Resolve repo name from git remote origin URL at a directory.
    public static func resolveGitRepoName(at path: String) -> String? {
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
            name = url.split(separator: "/").last.map { String($0) }?
                .replacingOccurrences(of: ".git", with: "") ?? ""
        }
        return name.isEmpty ? nil : name
    }
}
