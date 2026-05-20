import Foundation

struct TerminalDiagnosticsSnapshot {
    let selectedSessionName: String?
    let connectedSessionName: String?
    let activeTTY: String?
    let currentDirectory: String?
    let statusMessage: String
    let lastError: String?
}

enum SwiftMuxDiagnostics {
    static func makeReport(snapshot: TerminalDiagnosticsSnapshot) -> String {
        let appPID = ProcessInfo.processInfo.processIdentifier
        let childClients = swiftMuxChildAttachClients(appPID: appPID)
        let tmuxClients = tmuxClientLines()

        var sections: [String] = []
        sections.append(
            """
            SwiftMux
            app pid: \(appPID)
            selected session: \(snapshot.selectedSessionName ?? "none")
            connected session: \(snapshot.connectedSessionName ?? "none")
            active tty: \(snapshot.activeTTY ?? "unknown")
            current directory: \(snapshot.currentDirectory ?? "unknown")
            status: \(snapshot.statusMessage)
            last error: \(snapshot.lastError ?? "none")
            """
        )

        sections.append(commandSummary(title: "Tools", commands: [
            ("tmux", ["-V"]),
            ("tp", ["--version"])
        ]))

        sections.append(
            """
            SwiftMux-owned tmux attach clients
            count: \(childClients.count)
            \(formatAttachClients(childClients))
            """
        )

        sections.append(
            """
            tmux clients
            count: \(tmuxClients.count)
            \(tmuxClients.isEmpty ? "none" : tmuxClients.joined(separator: "\n"))
            """
        )

        return sections.joined(separator: "\n\n")
    }

    static func detachStaleTerminalClients(currentTTY: String?) -> String {
        let appPID = ProcessInfo.processInfo.processIdentifier
        let clients = swiftMuxChildAttachClients(appPID: appPID)
        let staleClients = clients.filter { client in
            guard let currentTTY, !currentTTY.isEmpty else {
                return true
            }
            return client.tty != currentTTY
        }

        guard !staleClients.isEmpty else {
            return "No stale SwiftMux terminal clients found."
        }

        var lines: [String] = []
        for client in staleClients {
            let output = try? CommandRunner.run(
                executable: "/usr/bin/env",
                arguments: ["tmux", "detach-client", "-t", client.tty]
            )

            if output?.exitCode == 0 {
                lines.append("detached \(client.tty) pid=\(client.pid) session=\(client.sessionName ?? "unknown")")
            } else {
                let message = output?.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                lines.append(
                    "failed \(client.tty) pid=\(client.pid): \(message?.isEmpty == false ? message! : "unknown error")"
                )
            }
        }

        return lines.joined(separator: "\n")
    }

    private static func commandSummary(title: String, commands: [(String, [String])]) -> String {
        var lines = [title]
        for (command, arguments) in commands {
            let output = try? CommandRunner.run(executable: "/usr/bin/env", arguments: [command] + arguments)
            let stdout = output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let stderr = output?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let value = stdout.nonEmpty ?? stderr.nonEmpty ?? "unavailable"
            lines.append("\(command): \(value)")
        }
        return lines.joined(separator: "\n")
    }

    private static func swiftMuxChildAttachClients(appPID: Int32) -> [SwiftMuxAttachClient] {
        let processLines = psLines()
        let tmuxClientsByPID = tmuxClientsByPID()

        return processLines.compactMap { line in
            guard line.ppid == appPID,
                  line.command.contains("tmux attach-session") else {
                return nil
            }

            let tmuxClient = tmuxClientsByPID[line.pid]
            return SwiftMuxAttachClient(
                pid: line.pid,
                ppid: line.ppid,
                tty: tmuxClient?.tty ?? "unknown",
                sessionName: tmuxClient?.sessionName ?? parseAttachedSessionName(from: line.command),
                command: line.command
            )
        }
    }

    private static func psLines() -> [ProcessLine] {
        guard let output = try? CommandRunner.run(
            executable: "/bin/ps",
            arguments: ["-axo", "pid=,ppid=,command="]
        ) else {
            return []
        }

        return output.stdout
            .split(whereSeparator: \.isNewline)
            .compactMap { ProcessLine(String($0)) }
    }

    private static func tmuxClientLines() -> [String] {
        guard let output = try? CommandRunner.run(
            executable: "/usr/bin/env",
            arguments: ["tmux", "list-clients", "-F", "#{client_pid}\t#{client_tty}\t#{session_name}"]
        ), output.exitCode == 0 else {
            return []
        }

        return output.stdout
            .split(whereSeparator: \.isNewline)
            .map(String.init)
    }

    private static func tmuxClientsByPID() -> [Int32: TmuxClient] {
        var clients: [Int32: TmuxClient] = [:]

        for line in tmuxClientLines() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard parts.count >= 3, let pid = Int32(parts[0]) else {
                continue
            }

            clients[pid] = TmuxClient(pid: pid, tty: parts[1], sessionName: parts[2])
        }

        return clients
    }

    private static func parseAttachedSessionName(from command: String) -> String? {
        let parts = command.split(separator: " ").map(String.init)
        for index in parts.indices where parts[index] == "-t" && index + 1 < parts.endIndex {
            return parts[index + 1]
        }
        return nil
    }

    private static func formatAttachClients(_ clients: [SwiftMuxAttachClient]) -> String {
        guard !clients.isEmpty else {
            return "none"
        }

        return clients
            .map { "\($0.pid)\t\($0.tty)\t\($0.sessionName ?? "unknown")\t\($0.command)" }
            .joined(separator: "\n")
    }
}

private struct ProcessLine {
    let pid: Int32
    let ppid: Int32
    let command: String

    init?(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count == 3,
              let pid = Int32(parts[0]),
              let ppid = Int32(parts[1]) else {
            return nil
        }

        self.pid = pid
        self.ppid = ppid
        command = String(parts[2])
    }
}

private struct TmuxClient {
    let pid: Int32
    let tty: String
    let sessionName: String
}

private struct SwiftMuxAttachClient {
    let pid: Int32
    let ppid: Int32
    let tty: String
    let sessionName: String?
    let command: String
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
