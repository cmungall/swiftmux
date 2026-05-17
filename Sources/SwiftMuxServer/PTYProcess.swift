import CSwiftMuxPTY
import Darwin
import Foundation

/// A child process attached to a pseudoterminal. Output bytes flow through
/// `outputStream`; write input via `write(_:)`; resize the pty with `resize`.
protocol TerminalBackend: AnyObject, Sendable {
    var outputStream: AsyncStream<Data> { get }

    func write(_ data: Data)
    func resize(rows: UInt16, cols: UInt16)
    func terminate()
}

final class PTYProcess: TerminalBackend, @unchecked Sendable {
    let outputStream: AsyncStream<Data>

    private let masterFD: Int32
    private let pid: pid_t
    private let outputContinuation: AsyncStream<Data>.Continuation
    private var readSource: DispatchSourceRead?
    private var hasTerminated = false
    private let lock = NSLock()

    init(
        executable: String,
        arguments: [String],
        rows: UInt16 = 24,
        cols: UInt16 = 80,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        var continuation: AsyncStream<Data>.Continuation!
        self.outputStream = AsyncStream<Data> { cont in
            continuation = cont
        }
        self.outputContinuation = continuation

        var master: Int32 = -1
        let pid = swiftmux_forkpty(&master, rows, cols)

        if pid < 0 {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }

        if pid == 0 {
            // Child: replace process image with the requested command.
            let argv: [UnsafeMutablePointer<CChar>?] =
                ([executable] + arguments).map { strdup($0) } + [nil]
            let envp: [UnsafeMutablePointer<CChar>?] =
                environment.map { strdup("\($0.key)=\($0.value)") } + [nil]

            argv.withUnsafeBufferPointer { argvBuf in
                envp.withUnsafeBufferPointer { envpBuf in
                    _ = execve(
                        executable,
                        UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                        UnsafeMutablePointer(mutating: envpBuf.baseAddress)
                    )
                }
            }
            // exec failed if we got here.
            _exit(127)
        }

        self.masterFD = master
        self.pid = pid

        // Set master fd non-blocking so the read source doesn't block.
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)

        let source = DispatchSource.makeReadSource(
            fileDescriptor: master,
            queue: DispatchQueue.global(qos: .userInitiated)
        )
        source.setEventHandler { [weak self] in
            self?.drainReadable()
        }
        source.setCancelHandler { [weak self] in
            guard let self else { return }
            close(self.masterFD)
        }
        source.resume()
        self.readSource = source
    }

    private func drainReadable() {
        var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = buffer.withUnsafeMutableBufferPointer { ptr in
                read(masterFD, ptr.baseAddress, ptr.count)
            }
            if n > 0 {
                outputContinuation.yield(Data(buffer.prefix(Int(n))))
            } else if n == 0 {
                // EOF: child closed its end.
                outputContinuation.finish()
                terminate()
                return
            } else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return
                }
                if errno == EINTR {
                    continue
                }
                outputContinuation.finish()
                terminate()
                return
            }
        }
    }

    func write(_ data: Data) {
        guard !data.isEmpty else { return }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var remaining = raw.count
            var offset = 0
            while remaining > 0 {
                let n = Darwin.write(masterFD, base.advanced(by: offset), remaining)
                if n > 0 {
                    offset += n
                    remaining -= n
                } else if n < 0 && (errno == EINTR) {
                    continue
                } else {
                    return
                }
            }
        }
    }

    func resize(rows: UInt16, cols: UInt16) {
        _ = swiftmux_set_winsize(masterFD, rows, cols)
    }

    func terminate() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasTerminated else { return }
        hasTerminated = true
        kill(pid, SIGHUP)
        readSource?.cancel()
        readSource = nil
        outputContinuation.finish()
    }

    deinit {
        terminate()
    }
}
