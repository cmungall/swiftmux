import AppKit
import SwiftTerm
import SwiftUI

struct TmuxTerminalView: NSViewRepresentable {
    let session: SessionInfo?
    @ObservedObject var terminalState: TmuxTerminalState

    func makeCoordinator() -> Coordinator {
        Coordinator(terminalState: terminalState)
    }

    func makeNSView(context: Context) -> LocalProcessTerminalView {
        let view = LocalProcessTerminalView(frame: .zero)
        view.processDelegate = context.coordinator
        view.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        view.nativeBackgroundColor = NSColor(calibratedRed: 0.07, green: 0.08, blue: 0.10, alpha: 1.0)
        view.nativeForegroundColor = NSColor(calibratedRed: 0.88, green: 0.91, blue: 0.94, alpha: 1.0)
        view.optionAsMetaKey = false
        view.allowMouseReporting = true
        view.getTerminal().silentLog = true
        context.coordinator.bind(view)
        return view
    }

    func updateNSView(_ nsView: LocalProcessTerminalView, context: Context) {
        context.coordinator.bind(nsView)
        context.coordinator.ensureAttached(to: session)
    }

    static func dismantleNSView(_ nsView: LocalProcessTerminalView, coordinator: Coordinator) {
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
        private var scrollMonitor: Any?
        private var preciseScrollAccumulator: CGFloat = 0
        private var lastPreciseScrollDirection = 0

        init(terminalState: TmuxTerminalState) {
            self.terminalState = terminalState
        }

        func bind(_ terminalView: LocalProcessTerminalView) {
            self.terminalView = terminalView
            installScrollMonitorIfNeeded()
        }

        func teardown() {
            ttyPollingTask?.cancel()
            switchTask?.cancel()
            resetPreciseScrollState()
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }

            if let ttyHandshakeURL {
                try? FileManager.default.removeItem(at: ttyHandshakeURL)
            }
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
            terminalState.prepareSwitch(to: targetSessionName)
            prepareTerminalForSessionTransition(in: terminalView)

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
            prepareTerminalForSessionTransition(in: terminalView)

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
            guard lastRequestedSessionName == sessionName else {
                return
            }

            launchedSessionName = sessionName
            terminalState.markSwitched(to: sessionName)
        }

        private func handleSwitchFailure(_ error: Error, sessionName: String) {
            guard lastRequestedSessionName == sessionName else {
                return
            }

            terminalState.reportError(error.localizedDescription)
            terminalState.requestReconnect(for: sessionName)
        }

        private func completeHandshake(sessionName: String, tty: String) {
            guard lastRequestedSessionName == sessionName else {
                return
            }

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

        private func prepareTerminalForSessionTransition(in terminalView: LocalProcessTerminalView) {
            resetPreciseScrollState()
            // The SwiftTerm view is reused while tmux switches sessions; clear its local
            // emulator state before tmux redraws so the scrollbar cannot expose old scrollback.
            terminalView.feed(text: "\u{1B}c")
        }

        private func installScrollMonitorIfNeeded() {
            guard scrollMonitor == nil else {
                return
            }

            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, self.handleScrollWheel(event) else {
                    return event
                }

                return nil
            }
        }

        private func handleScrollWheel(_ event: NSEvent) -> Bool {
            guard let terminalView else {
                return false
            }

            let terminal = terminalView.getTerminal()
            guard terminalView.allowMouseReporting, terminal.mouseMode != .off else {
                return false
            }

            guard event.window === terminalView.window else {
                return false
            }

            let point = terminalView.convert(event.locationInWindow, from: nil)
            guard terminalView.bounds.contains(point) else {
                return false
            }

            let scrollSteps = scrollSteps(for: event, in: terminalView, terminal: terminal)
            guard scrollSteps != 0 else {
                return event.hasPreciseScrollingDeltas || !event.momentumPhase.isEmpty
            }

            let hit = mouseHit(for: point, in: terminalView, terminal: terminal)
            let modifiers = event.modifierFlags
            let button = scrollSteps > 0 ? 4 : 5

            for _ in 0..<abs(scrollSteps) {
                let buttonFlags = terminal.encodeButton(
                    button: button,
                    release: false,
                    shift: modifiers.contains(.shift),
                    meta: modifiers.contains(.option),
                    control: modifiers.contains(.control)
                )

                terminal.sendEvent(
                    buttonFlags: buttonFlags,
                    x: hit.grid.col,
                    y: hit.grid.row,
                    pixelX: hit.pixel.col,
                    pixelY: hit.pixel.row
                )
            }
            return true
        }

        private func scrollSteps(
            for event: NSEvent,
            in terminalView: LocalProcessTerminalView,
            terminal: Terminal
        ) -> Int {
            if !event.momentumPhase.isEmpty {
                resetPreciseScrollState()
                return 0
            }

            let deltaY = event.scrollingDeltaY == 0 ? event.deltaY : event.scrollingDeltaY
            guard deltaY != 0 else {
                if !event.phase.isEmpty {
                    resetPreciseScrollState()
                }
                return 0
            }

            if !event.hasPreciseScrollingDeltas {
                resetPreciseScrollState()
                let steps = max(Int(abs(deltaY).rounded(.awayFromZero)), 1)
                return deltaY > 0 ? steps : -steps
            }

            let direction = deltaY > 0 ? 1 : -1
            if direction != lastPreciseScrollDirection {
                preciseScrollAccumulator = 0
                lastPreciseScrollDirection = direction
            }

            let rows = max(terminal.rows, 1)
            let lineHeight = max(terminalView.bounds.height / CGFloat(rows), 1)
            preciseScrollAccumulator += deltaY

            let steps = Int(abs(preciseScrollAccumulator) / lineHeight)
            if steps > 0 {
                preciseScrollAccumulator -= CGFloat(direction * steps) * lineHeight
            }

            if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
                resetPreciseScrollState()
            }

            return direction * steps
        }

        private func resetPreciseScrollState() {
            preciseScrollAccumulator = 0
            lastPreciseScrollDirection = 0
        }

        private func mouseHit(
            for point: CGPoint,
            in terminalView: LocalProcessTerminalView,
            terminal: Terminal
        ) -> (grid: Position, pixel: Position) {
            let clampedX = min(max(point.x, 0), terminalView.bounds.width)
            let clampedY = min(max(point.y, 0), terminalView.bounds.height)
            let cols = max(terminal.cols, 1)
            let rows = max(terminal.rows, 1)
            let cellWidth = max(terminalView.bounds.width / CGFloat(cols), 1)
            let cellHeight = max(terminalView.bounds.height / CGFloat(rows), 1)

            let gridCol = min(max(Int(clampedX / cellWidth), 0), cols - 1)
            let gridRow = min(max(Int((terminalView.bounds.height - clampedY) / cellHeight), 0), rows - 1)
            let pixelCol = Int(clampedX)
            let pixelRow = Int(terminalView.bounds.height - clampedY)

            return (
                grid: Position(col: gridCol, row: gridRow),
                pixel: Position(col: pixelCol, row: pixelRow)
            )
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
