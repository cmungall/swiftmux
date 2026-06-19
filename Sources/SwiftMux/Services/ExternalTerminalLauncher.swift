import AppKit
import Foundation

enum ExternalTerminalLauncherError: LocalizedError {
    case noSupportedTerminal
    case launchFailed(appName: String, message: String)

    var errorDescription: String? {
        switch self {
        case .noSupportedTerminal:
            return "Install Ghostty, iTerm2, or use Terminal.app to open an external tmux client."
        case .launchFailed(let appName, let message):
            return "\(appName) launch failed: \(message)"
        }
    }
}

enum ExternalTerminalLauncher {
    @MainActor
    static func open(sessionName: String, workingDirectory: String) async throws {
        guard let app = TerminalApp.preferredInstalledApp() else {
            throw ExternalTerminalLauncherError.noSupportedTerminal
        }

        let title = terminalTitle(for: sessionName)
        let command = attachCommand(
            sessionName: sessionName,
            title: title,
            workingDirectory: workingDirectory
        )
        let script = app.script
        let appName = app.displayName

        try await Task.detached(priority: .userInitiated) {
            let output = try CommandRunner.run(
                executable: "/usr/bin/env",
                arguments: [
                    "osascript",
                    "-e",
                    script,
                    "--",
                    title,
                    sessionName,
                    command,
                    workingDirectory
                ]
            )

            guard output.exitCode == 0 else {
                let stderr = output.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdout = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                let message = stderr.isEmpty ? (stdout.isEmpty ? "osascript exited with status \(output.exitCode)." : stdout) : stderr
                throw ExternalTerminalLauncherError.launchFailed(appName: appName, message: message)
            }
        }.value
    }

    private static func terminalTitle(for sessionName: String) -> String {
        "SwiftMux: \(sessionName)"
    }

    private static func attachCommand(sessionName: String, title: String, workingDirectory: String) -> String {
        [
            "cd \(shellQuoted(workingDirectory)) 2>/dev/null || true",
            "printf '\\033]0;%s\\007' \(shellQuoted(title))",
            "tmux set-option -t \(shellQuoted(sessionName)) mouse on 2>/dev/null || true",
            "tmux set-option -t \(shellQuoted(sessionName)) set-titles on 2>/dev/null || true",
            "tmux set-option -t \(shellQuoted(sessionName)) set-titles-string \(shellQuoted(tmuxFormatLiteral(title))) 2>/dev/null || true",
            "exec tmux attach-session -t \(shellQuoted(sessionName))"
        ].joined(separator: "; ")
    }

    private static func tmuxFormatLiteral(_ value: String) -> String {
        value.replacingOccurrences(of: "#", with: "##")
    }

    private static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}

private enum TerminalApp: Sendable {
    case ghostty
    case iTerm2
    case terminal

    var displayName: String {
        switch self {
        case .ghostty:
            return "Ghostty"
        case .iTerm2:
            return "iTerm2"
        case .terminal:
            return "Terminal"
        }
    }

    var bundleIdentifier: String {
        switch self {
        case .ghostty:
            return "com.mitchellh.ghostty"
        case .iTerm2:
            return "com.googlecode.iterm2"
        case .terminal:
            return "com.apple.Terminal"
        }
    }

    var script: String {
        switch self {
        case .ghostty:
            return """
            on run argv
                set targetTitle to item 1 of argv
                set commandText to item 3 of argv
                set workingDirectory to item 4 of argv
                set targetWindow to missing value

                tell application id "com.mitchellh.ghostty"
                    activate

                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aTerminal in terminals of aTab
                                if (name of aTerminal) contains targetTitle then
                                    focus aTerminal
                                    return "focused"
                                end if
                                if (targetWindow is missing value) and ((name of aTerminal) contains "SwiftMux: ") then
                                    set targetWindow to aWindow
                                end if
                            end repeat
                        end repeat
                    end repeat

                    set cfg to new surface configuration
                    set initial working directory of cfg to workingDirectory
                    set initial input of cfg to commandText & linefeed
                    if targetWindow is missing value then
                        set newWindow to new window with configuration cfg
                        activate window newWindow
                    else
                        set newTab to new tab in targetWindow with configuration cfg
                        select tab newTab
                        activate window targetWindow
                    end if
                    return "created"
                end tell
            end run
            """
        case .iTerm2:
            return """
            on run argv
                set targetTitle to item 1 of argv
                set targetSession to item 2 of argv
                set commandText to item 3 of argv
                set targetWindow to missing value

                tell application id "com.googlecode.iterm2"
                    activate

                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            repeat with aSession in sessions of aTab
                                set isMatch to false
                                tell aSession
                                    try
                                        if (variable "user.swiftmux_session") is targetSession then
                                            set isMatch to true
                                        end if
                                    end try
                                    if (isMatch is false) and ((name) contains targetTitle) then
                                        set isMatch to true
                                    end if
                                    if targetWindow is missing value then
                                        try
                                            if (variable "user.swiftmux_session") is not "" then
                                                set targetWindow to aWindow
                                            end if
                                        end try
                                        if targetWindow is missing value and ((name) contains "SwiftMux: ") then
                                            set targetWindow to aWindow
                                        end if
                                    end if
                                end tell
                                if isMatch then
                                    select aSession
                                    select aTab
                                    select aWindow
                                    return "focused"
                                end if
                            end repeat
                        end repeat
                    end repeat

                    if targetWindow is missing value then
                        set newWindow to (create window with default profile command commandText)
                        set newSession to current session of newWindow
                        set newTab to current tab of newWindow
                        set targetWindow to newWindow
                    else
                        tell targetWindow
                            set newTab to (create tab with default profile command commandText)
                            set newSession to current session of newTab
                        end tell
                    end if
                    tell newSession
                        set name to targetTitle
                        set variable named "user.swiftmux_session" to targetSession
                    end tell
                    select newSession
                    select newTab
                    select targetWindow
                    return "created"
                end tell
            end run
            """
        case .terminal:
            return """
            on run argv
                set targetTitle to item 1 of argv
                set commandText to item 3 of argv

                tell application id "com.apple.Terminal"
                    activate

                    repeat with aWindow in windows
                        repeat with aTab in tabs of aWindow
                            if (custom title of aTab) is targetTitle then
                                set selected of aTab to true
                                set frontmost of aWindow to true
                                return "focused"
                            end if
                        end repeat
                    end repeat

                    set newTab to do script commandText
                    set custom title of newTab to targetTitle
                    set title displays custom title of newTab to true
                    return "created"
                end tell
            end run
            """
        }
    }

    @MainActor
    static func preferredInstalledApp() -> TerminalApp? {
        for app in [TerminalApp.ghostty, .iTerm2, .terminal] {
            if NSWorkspace.shared.urlForApplication(withBundleIdentifier: app.bundleIdentifier) != nil {
                return app
            }
        }

        return nil
    }
}
