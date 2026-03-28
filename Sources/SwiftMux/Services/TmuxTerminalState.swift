import Foundation

@MainActor
final class TmuxTerminalState: ObservableObject {
    @Published var resetToken = UUID()
    @Published private(set) var connectedSessionName: String?
    @Published private(set) var currentDirectory: String?
    @Published private(set) var terminalTitle = "SwiftMux"
    @Published private(set) var statusMessage = "Select a tmux session"
    @Published private(set) var lastError: String?

    func prepareLaunch(for sessionName: String) -> URL {
        connectedSessionName = nil
        currentDirectory = nil
        terminalTitle = "SwiftMux"
        statusMessage = "Attaching \(sessionName)"
        lastError = nil

        let safeName = sessionName.replacingOccurrences(of: "/", with: "-")
        return FileManager.default.temporaryDirectory
            .appendingPathComponent("swiftmux-\(safeName)-\(UUID().uuidString)")
            .appendingPathExtension("tty")
    }

    func markConnected(sessionName: String, tty: String) {
        connectedSessionName = sessionName
        statusMessage = "Attached to \(sessionName) on \(tty)"
        lastError = nil
    }

    func markSwitched(to sessionName: String) {
        connectedSessionName = sessionName
        statusMessage = "Attached to \(sessionName)"
        lastError = nil
    }

    func updateTitle(_ title: String) {
        guard !title.isEmpty else {
            return
        }

        terminalTitle = title
    }

    func updateCurrentDirectory(_ directory: String?) {
        currentDirectory = directory
    }

    func reportError(_ message: String) {
        statusMessage = message
        lastError = message
    }

    func markDetached(message: String) {
        connectedSessionName = nil
        reportError(message)
    }

    func requestReconnect(for sessionName: String?) {
        guard let sessionName else {
            return
        }

        statusMessage = "Reconnecting \(sessionName)"
        lastError = nil
        resetToken = UUID()
    }
}
