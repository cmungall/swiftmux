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
        private var pendingSwitchSessionName: String?
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
            pendingSwitchSessionName = nil
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
                pendingSwitchSessionName = nil
                return
            }

            guard pendingSwitchSessionName != session.name else {
                return
            }

            guard let activeTTY else {
                deferTerminalStateUpdate { state in
                    state.requestReconnect(for: session.name)
                }
                return
            }

            switchTask?.cancel()
            let targetSessionName = session.name
            pendingSwitchSessionName = targetSessionName
            resetPreciseScrollState()
            deferTerminalStateUpdate { state in
                state.prepareSwitch(to: targetSessionName)
            }
            deferSwitch(to: targetSessionName, activeTTY: activeTTY, in: terminalView)
        }

        private func startSwitch(to targetSessionName: String, activeTTY: String) {
            switchTask?.cancel()
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
            pendingSwitchSessionName = nil

            let ttyHandshakeURL = TmuxTerminalState.ttyHandshakeURL(for: sessionName)
            try? FileManager.default.removeItem(at: ttyHandshakeURL)

            self.ttyHandshakeURL = ttyHandshakeURL
            self.activeTTY = nil
            self.launchedSessionName = sessionName
            deferTerminalStateUpdate { state in
                state.prepareLaunch(for: sessionName)
            }

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
            pendingSwitchSessionName = nil
            terminalState.markSwitched(to: sessionName)
        }

        private func handleSwitchFailure(_ error: Error, sessionName: String) {
            guard lastRequestedSessionName == sessionName else {
                return
            }

            pendingSwitchSessionName = nil
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

        private func deferTerminalStateUpdate(_ update: @escaping @MainActor (TmuxTerminalState) -> Void) {
            DispatchQueue.main.async { [terminalState] in
                Task { @MainActor in
                    update(terminalState)
                }
            }
        }

        private func deferSwitch(
            to targetSessionName: String,
            activeTTY: String,
            in terminalView: LocalProcessTerminalView
        ) {
            DispatchQueue.main.async { [weak self, weak terminalView] in
                Task { @MainActor [weak self, weak terminalView] in
                    guard let self,
                          let terminalView,
                          self.lastRequestedSessionName == targetSessionName,
                          self.pendingSwitchSessionName == targetSessionName else {
                        return
                    }

                    self.prepareTerminalForSessionTransition(in: terminalView)
                    self.startSwitch(to: targetSessionName, activeTTY: activeTTY)
                }
            }
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

        private func prepareTerminalForSessionTransition(in terminalView: LocalProcessTerminalView) {
            resetPreciseScrollState()
            // The SwiftTerm view is reused while tmux switches sessions; clear its local
            // emulator state before tmux redraws so the scrollbar cannot expose old scrollback.
            terminalView.feed(text: "\u{1B}c")
        }

        private func handleScrollWheel(_ event: NSEvent) -> Bool {
            guard let terminalView,
                  let terminalWindow = terminalView.window,
                  let eventWindow = event.window,
                  eventWindow === terminalWindow else {
                return false
            }

            let terminal = terminalView.getTerminal()
            let point = terminalView.convert(event.locationInWindow, from: nil)
            guard terminalView.bounds.contains(point) else {
                resetPreciseScrollState()
                return false
            }

            let scrollSteps = scrollSteps(for: event, in: terminalView, terminal: terminal)
            guard terminalView.allowMouseReporting, terminal.mouseMode != .off else {
                if scrollSteps != 0 {
                    scrollActiveTmuxPaneInCopyMode(steps: scrollSteps)
                }
                return scrollSteps != 0 || event.hasPreciseScrollingDeltas || !event.momentumPhase.isEmpty
            }

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

        private func scrollActiveTmuxPaneInCopyMode(steps: Int) {
            let tty = activeTTY
            let sessionName = launchedSessionName
            let lineCount = min(max(abs(steps) * 5, 1), 200)
            let action = steps > 0 ? "scroll-up" : "scroll-down"

            Task.detached(priority: .userInitiated) {
                guard let pane = Self.resolveActivePane(tty: tty, sessionName: sessionName) else {
                    return
                }

                if steps > 0 {
                    _ = try? CommandRunner.run(
                        executable: "/usr/bin/env",
                        arguments: ["tmux", "copy-mode", "-t", pane]
                    )
                }

                let output = try? CommandRunner.run(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "send-keys", "-t", pane, "-X", "-N", String(lineCount), action]
                )

                guard steps < 0, output?.exitCode == 0 else {
                    return
                }

                let scrollPosition = try? CommandRunner.run(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "display-message", "-p", "-t", pane, "#{scroll_position}"]
                )
                guard scrollPosition?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "0" else {
                    return
                }

                _ = try? CommandRunner.run(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "send-keys", "-t", pane, "-X", "cancel"]
                )
            }
        }

        nonisolated private static func resolveActivePane(tty: String?, sessionName: String?) -> String? {
            if let tty, !tty.isEmpty {
                let output = try? CommandRunner.run(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "display-message", "-p", "-c", tty, "#{pane_id}"]
                )
                let pane = output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if output?.exitCode == 0, !pane.isEmpty {
                    return pane
                }
            }

            guard let sessionName, !sessionName.isEmpty else {
                return nil
            }

            let output = try? CommandRunner.run(
                executable: "/usr/bin/env",
                arguments: ["tmux", "display-message", "-p", "-t", sessionName, "#{pane_id}"]
            )
            let pane = output?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return output?.exitCode == 0 && !pane.isEmpty ? pane : nil
        }

        private func scrollSteps(
            for event: NSEvent,
            in terminalView: LocalProcessTerminalView,
            terminal: Terminal
        ) -> Int {
            if event.phase.contains(.began) || !event.momentumPhase.isEmpty {
                resetPreciseScrollState()
            }

            if !event.momentumPhase.isEmpty {
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
