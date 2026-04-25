import Foundation
import Hummingbird
import HummingbirdWebSocket
import NIOCore
import SwiftMuxCore

/// Wire protocol:
///   client → server:
///     • Text frame whose first char is `{` and decodes as ControlMessage → control (resize/etc.)
///     • Otherwise text frame → write the bytes to the PTY (keyboard input)
///     • Binary frame → write the bytes to the PTY
///   server → client:
///     • Binary frames carrying raw PTY output bytes
struct ControlMessage: Codable {
    let type: String
    let rows: UInt16?
    let cols: UInt16?
}

enum TerminalWebSocket {
    static func register(on router: Router<BasicWebSocketRequestContext>) {
        router.ws("/ws/sessions/:name") { inbound, outbound, context in
            let name = context.parameters.get("name") ?? ""
            guard !name.isEmpty else { return }

            let pty: PTYProcess
            do {
                pty = try PTYProcess(
                    executable: "/usr/bin/env",
                    arguments: ["tmux", "attach", "-t", name],
                    rows: 40,
                    cols: 120,
                    environment: CommandRunner.mergedEnvironment(with: ["TERM": "xterm-256color"])
                )
            } catch {
                try? await outbound.write(.text("error: failed to attach: \(error)"))
                return
            }

            // Forward PTY output → WebSocket as binary frames.
            let outputTask = Task {
                for await chunk in pty.outputStream {
                    var buffer = ByteBuffer()
                    buffer.writeBytes(chunk)
                    try? await outbound.write(.binary(buffer))
                }
            }

            // Forward WebSocket input → PTY.
            do {
                for try await message in inbound.messages(maxSize: 1 << 20) {
                    switch message {
                    case .text(let text):
                        if text.first == "{",
                           let data = text.data(using: .utf8),
                           let control = try? JSONDecoder().decode(ControlMessage.self, from: data) {
                            handleControl(control, on: pty)
                        } else {
                            pty.write(Data(text.utf8))
                        }
                    case .binary(let buffer):
                        var buf = buffer
                        if let bytes = buf.readBytes(length: buf.readableBytes) {
                            pty.write(Data(bytes))
                        }
                    }
                }
            } catch {
                // socket closed or errored — fall through to cleanup
            }

            outputTask.cancel()
            pty.terminate()
        }
    }

    private static func handleControl(_ msg: ControlMessage, on pty: PTYProcess) {
        switch msg.type {
        case "resize":
            if let rows = msg.rows, let cols = msg.cols, rows > 0, cols > 0 {
                pty.resize(rows: rows, cols: cols)
            }
        default:
            break
        }
    }
}
