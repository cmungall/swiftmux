import Foundation
import SwiftMuxCore

/// Fallback tmux backend for systems that cannot allocate another pty.
///
/// It periodically renders the active pane with `tmux capture-pane` and sends
/// browser input through `tmux send-keys`. This is less faithful than attaching
/// through a real pty, but it keeps remote control usable when the pty pool is
/// exhausted.
final class TmuxCaptureBridge: TerminalBackend, @unchecked Sendable {
    let outputStream: AsyncStream<Data>

    private let sessionName: String
    private let outputContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var pollTask: Task<Void, Never>?
    private var lastRenderedText = ""
    private var hasTerminated = false

    init(sessionName: String) throws {
        self.sessionName = sessionName

        var continuation: AsyncStream<Data>.Continuation!
        self.outputStream = AsyncStream<Data> { cont in
            continuation = cont
        }
        self.outputContinuation = continuation

        _ = try CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tmux", "has-session", "-t", sessionName]
        )

        pollTask = Task { [weak self] in
            await self?.poll()
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }

        let bytes = [UInt8](data)
        var index = 0
        var literal = Data()

        func flushLiteral() {
            guard !literal.isEmpty else { return }
            if let text = String(data: literal, encoding: .utf8), !text.isEmpty {
                sendLiteral(text)
            }
            literal.removeAll(keepingCapacity: true)
        }

        while index < bytes.count {
            let byte = bytes[index]

            switch byte {
            case 0x1B:
                flushLiteral()
                if index + 2 < bytes.count, bytes[index + 1] == 0x5B {
                    switch bytes[index + 2] {
                    case 0x41:
                        sendKey("Up")
                    case 0x42:
                        sendKey("Down")
                    case 0x43:
                        sendKey("Right")
                    case 0x44:
                        sendKey("Left")
                    default:
                        sendKey("Escape")
                    }
                    index += 3
                } else {
                    sendKey("Escape")
                    index += 1
                }
            case 0x0D, 0x0A:
                flushLiteral()
                sendKey("Enter")
                index += 1
            case 0x09:
                flushLiteral()
                sendKey("Tab")
                index += 1
            case 0x7F, 0x08:
                flushLiteral()
                sendKey("BSpace")
                index += 1
            case 0x01...0x1A:
                flushLiteral()
                let scalar = UnicodeScalar(UInt8(ascii: "a") + byte - 1)
                sendKey("C-\(Character(scalar))")
                index += 1
            default:
                literal.append(byte)
                index += 1
            }
        }

        flushLiteral()
        captureAndEmit(force: true)
    }

    func resize(rows: UInt16, cols: UInt16) {
        // The fallback does not resize the tmux pane because that would resize
        // the shared pane for every attached client. The browser fits whatever
        // the existing tmux pane is currently rendering.
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }

        guard !hasTerminated else { return }
        hasTerminated = true
        pollTask?.cancel()
        pollTask = nil
        outputContinuation.finish()
    }

    deinit {
        terminate()
    }

    private func poll() async {
        while !Task.isCancelled {
            captureAndEmit(force: false)
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func captureAndEmit(force: Bool) {
        guard !hasTerminated else { return }

        do {
            let output = try CommandRunner.runExpectingSuccess(
                executable: "/usr/bin/env",
                arguments: ["tmux", "capture-pane", "-ep", "-t", sessionName]
            )
            let text = output.stdout
            guard force || text != lastRenderedText else {
                return
            }
            lastRenderedText = text
            outputContinuation.yield(renderFrame(for: text))
        } catch {
            outputContinuation.yield(renderFrame(for: "tmux capture failed: \(error.localizedDescription)"))
        }
    }

    private func sendLiteral(_ text: String) {
        _ = try? CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tmux", "send-keys", "-l", "-t", sessionName, "--", text]
        )
    }

    private func sendKey(_ key: String) {
        _ = try? CommandRunner.runExpectingSuccess(
            executable: "/usr/bin/env",
            arguments: ["tmux", "send-keys", "-t", sessionName, key]
        )
    }

    private func renderFrame(for text: String) -> Data {
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: "\n")
            .joined(separator: "\r\n")

        return Data("\u{001B}[0m\u{001B}[H\u{001B}[2J\(normalized)\u{001B}[0m".utf8)
    }
}
