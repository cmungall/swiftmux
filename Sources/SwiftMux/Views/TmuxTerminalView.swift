import AppKit
import SwiftTerm
import SwiftUI

struct TmuxTerminalView: NSViewRepresentable {
    let session: SessionInfo?
    @ObservedObject var terminalState: TmuxTerminalState

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalState: terminalState)
    }

    func makeNSView(context: Context) -> SwiftMuxTerminalView {
        let view = SwiftMuxTerminalView(frame: .zero)
        let coordinator = context.coordinator
        view.processDelegate = context.coordinator
        view.openErrorHandler = { [weak coordinator] message in
            Task { @MainActor in
                coordinator?.reportOpenError(message)
            }
        }
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.94, alpha: 1.0)
        view.optionAsMetaKey = false
        view.allowMouseReporting = true
        view.getTerminal().silentLog = true
        context.coordinator.bind(view)
        return view
    }

    func updateNSView(_ nsView: SwiftMuxTerminalView, context: Context) {
        nsView.currentWorkingDirectory = terminalState.currentDirectory
        nsView.sessionWorkingDirectory = session?.resolvedWorkingDirectory
        context.coordinator.bind(nsView)
        context.coordinator.ensureAttached(to: session)
    }

    static func dismantleNSView(_ nsView: SwiftMuxTerminalView, coordinator: Coordinator) {
        coordinator.teardown()
    }

    @MainActor
    final class Coordinator: NSObject, LocalProcessTerminalViewDelegate {
        private weak var terminalView: LocalProcessTerminalView?
        private let terminalState: TmuxTerminalState
        private var launchedSessionName: String?
        private var ttyHandshakeURL: URL?
        private var activeTTY: String?
        private var ttyPollingTask: Task<Void, Never>?
        private var switchTask: Task<Void, Never>?
        private var lastRequestedSessionName: String?
        private var eventMonitor: Any?
        private var suppressMouseUntilUp = false

        init(terminalState: TmuxTerminalState) {
            self.terminalState = terminalState
        }

        func bind(_ terminalView: LocalProcessTerminalView) {
            self.terminalView = terminalView
            installEventMonitorIfNeeded()
        }

        func teardown() {
            ttyPollingTask?.cancel()
            switchTask?.cancel()
            detachActiveTmuxClient()
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }

            if let ttyHandshakeURL {
                try? FileManager.default.removeItem(at: ttyHandshakeURL)
            }
        }

        func reportOpenError(_ message: String) {
            terminalState.reportError(message)
        }

        func ensureAttached(to session: SessionInfo?) {
            guard let terminalView, let session else {
                return
            }

            lastRequestedSessionName = session.name

            if launchedSessionName == nil {
                launch(sessionName: session.name, in: terminalView)
                return
            }

            guard launchedSessionName != session.name else {
                return
            }

            guard let activeTTY else {
                terminalState.requestReconnect(for: session.name)
                return
            }

            switchTask?.cancel()
            let targetSessionName = session.name
            switchTask = Task.detached(priority: .userInitiated) { [weak self] in
                do {
                    _ = try CommandRunner.runExpectingSuccess(
                        executable: "/usr/bin/env",
                        arguments: ["tmux", "switch-client", "-c", activeTTY, "-t", targetSessionName]
                    )

                    await self?.completeSwitch(to: targetSessionName)
                } catch {
                    await self?.handleSwitchFailure(error, sessionName: targetSessionName)
                }
            }
        }

        private func launch(sessionName: String, in terminalView: LocalProcessTerminalView) {
            ttyPollingTask?.cancel()
            switchTask?.cancel()

            let ttyHandshakeURL = terminalState.prepareLaunch(for: sessionName)
            try? FileManager.default.removeItem(at: ttyHandshakeURL)

            self.ttyHandshakeURL = ttyHandshakeURL
            self.activeTTY = nil
            self.launchedSessionName = sessionName

            // Respect the session's existing tmux mouse configuration so native text selection keeps working.
            let shellCommand = "tty > \(shellQuoted(ttyHandshakeURL.path)); exec tmux attach-session -t \(shellQuoted(sessionName))"

            terminalView.startProcess(
                executable: "/bin/sh",
                args: ["-lc", shellCommand],
                environment: terminalEnvironment()
            )

            beginTTYHandshakePolling(for: ttyHandshakeURL, sessionName: sessionName)
        }

        private func beginTTYHandshakePolling(for url: URL, sessionName: String) {
            ttyPollingTask?.cancel()
            ttyPollingTask = Task.detached(priority: .userInitiated) { [weak self] in
                for _ in 0..<50 {
                    if Task.isCancelled {
                        return
                    }

                    if let tty = try? String(contentsOf: url, encoding: .utf8)
                        .trimmingCharacters(in: .whitespacesAndNewlines),
                       !tty.isEmpty {
                        await self?.completeHandshake(sessionName: sessionName, tty: tty)
                        return
                    }

                    try? await Task.sleep(nanoseconds: 100_000_000)
                }

                await self?.handleHandshakeFailure()
            }
        }

        private func completeSwitch(to sessionName: String) {
            launchedSessionName = sessionName
            terminalState.markSwitched(to: sessionName)
        }

        private func handleSwitchFailure(_ error: Error, sessionName: String) {
            terminalState.reportError(error.localizedDescription)
            terminalState.requestReconnect(for: sessionName)
        }

        private func completeHandshake(sessionName: String, tty: String) {
            activeTTY = tty
            terminalState.markConnected(sessionName: sessionName, tty: tty)
        }

        private func handleHandshakeFailure() {
            terminalState.reportError("Failed to discover the tmux client TTY.")
        }

        private func terminalEnvironment() -> [String] {
            var environment: [String: String] = [:]

            for pair in Terminal.getEnvironmentVariables(termName: "xterm-256color") {
                let parts = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    continue
                }

                environment[parts[0]] = parts[1]
            }

            for (key, value) in CommandRunner.baseEnvironment() {
                environment[key] = value
            }

            environment["TERM_PROGRAM"] = "SwiftMux"

            return environment.keys.sorted().compactMap { key in
                guard let value = environment[key] else {
                    return nil
                }

                return "\(key)=\(value)"
            }
        }

        private func shellQuoted(_ value: String) -> String {
            "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
        }

        private func detachActiveTmuxClient() {
            let discoveredTTY = activeTTY ?? ttyHandshakeURL.flatMap {
                try? String(contentsOf: $0, encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let discoveredTTY, !discoveredTTY.isEmpty else {
                return
            }

            Task.detached(priority: .utility) {
                _ = try? CommandRunner.run(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "detach-client", "-t", discoveredTTY]
                )
            }
        }

        private func installEventMonitorIfNeeded() {
            guard eventMonitor == nil else {
                return
            }

            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.scrollWheel, .leftMouseDown, .leftMouseDragged, .leftMouseUp]
            ) { [weak self] event in
                self?.handleTerminalEvent(event) ?? event
            }
        }

        private func handleTerminalEvent(_ event: NSEvent) -> NSEvent? {
            guard let terminalView = terminalView as? SwiftMuxTerminalView else {
                return event
            }

            if suppressMouseUntilUp {
                switch event.type {
                case .leftMouseDragged:
                    _ = terminalView.cancelPendingCommandClick()
                    return nil
                case .leftMouseUp:
                    suppressMouseUntilUp = false
                    _ = terminalView.completeCommandClick(with: event)
                    return nil
                default:
                    break
                }
            }

            guard terminalView.containsEventLocation(event) else {
                return event
            }

            switch event.type {
            case .scrollWheel:
                return terminalView.handleScrollWheel(event) ? nil : event
            case .leftMouseDown:
                if terminalView.beginCommandClick(with: event) {
                    suppressMouseUntilUp = true
                    return nil
                }
                return event
            default:
                return event
            }
        }

        nonisolated func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

        nonisolated func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
            Task { @MainActor in
                terminalState.updateTitle(title)
            }
        }

        nonisolated func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
            Task { @MainActor in
                terminalState.updateCurrentDirectory(directory)
            }
        }

        nonisolated func processTerminated(source: TerminalView, exitCode: Int32?) {
            let message: String
            if let exitCode {
                message = "tmux client exited with code \(exitCode)."
            } else {
                message = "tmux client terminated."
            }

            Task { @MainActor in
                ttyPollingTask?.cancel()
                switchTask?.cancel()
                activeTTY = nil
                launchedSessionName = nil
                terminalState.markDetached(message: message)
            }
        }
    }
}
