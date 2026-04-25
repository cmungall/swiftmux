import Foundation

public struct CommandOutput {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32

    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum CommandRunnerError: LocalizedError {
    case missingExecutable(String)
    case executionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let message):
            return message
        case .executionFailed(let message):
            return message
        }
    }
}

public enum CommandRunner {
    public static func run(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> CommandOutput {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = mergedEnvironment(with: environment)

        do {
            try process.run()
        } catch {
            throw CommandRunnerError.missingExecutable("Failed to launch \(executable): \(error.localizedDescription)")
        }

        process.waitUntilExit()

        let stdout = String(
            data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        let stderr = String(
            data: stderrPipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""

        return CommandOutput(stdout: stdout, stderr: stderr, exitCode: process.terminationStatus)
    }

    public static func runExpectingSuccess(
        executable: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> CommandOutput {
        let output = try run(
            executable: executable,
            arguments: arguments,
            environment: environment
        )

        guard output.exitCode == 0 else {
            let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let message = stderr.isEmpty ? "Command exited with status \(output.exitCode)." : stderr
            throw CommandRunnerError.executionFailed(message)
        }

        return output
    }

    public static func baseEnvironment() -> [String: String] {
        mergedEnvironment(with: [:])
    }

    public static func mergedEnvironment(with overrides: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = resolvedPath(existing: environment["PATH"])
        environment["LANG"] = environment["LANG"] ?? "en_US.UTF-8"
        environment["LC_ALL"] = environment["LC_ALL"] ?? "en_US.UTF-8"

        for (key, value) in overrides {
            environment[key] = value
        }

        return environment
    }

    private static func resolvedPath(existing: String?) -> String {
        let home = NSHomeDirectory()
        let existingParts = (existing ?? "")
            .split(separator: ":")
            .map(String.init)

        let preferredParts = [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]

        var ordered: [String] = []
        for part in preferredParts + existingParts {
            guard !part.isEmpty, !ordered.contains(part) else {
                continue
            }
            ordered.append(part)
        }

        return ordered.joined(separator: ":")
    }
}
