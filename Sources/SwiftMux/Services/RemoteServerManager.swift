import Foundation
import Darwin
import Security

enum RemoteServerBindMode: String, CaseIterable, Identifiable {
    case local
    case network

    var id: String { rawValue }

    var title: String {
        switch self {
        case .local:
            return "Local"
        case .network:
            return "Network"
        }
    }

    var host: String {
        switch self {
        case .local:
            return "127.0.0.1"
        case .network:
            return "0.0.0.0"
        }
    }
}

@MainActor
final class RemoteServerManager: ObservableObject {
    enum State: Equatable {
        case stopped
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: State = .stopped
    @Published private(set) var host = RemoteServerBindMode.local.host
    @Published private(set) var port = 8421
    @Published private(set) var token: String?
    @Published private(set) var processID: Int32?
    @Published private(set) var launchCommand = ""
    @Published private(set) var logText = ""

    private var process: Process?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var readinessTask: Task<Void, Never>?
    private var requestedStop = false

    deinit {
        readinessTask?.cancel()
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        if process?.isRunning == true {
            process?.terminate()
        }
    }

    var isActive: Bool {
        switch state {
        case .starting, .running:
            return true
        case .stopped, .failed:
            return false
        }
    }

    var isRunning: Bool {
        state == .running
    }

    var statusText: String {
        switch state {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting"
        case .running:
            return "Running"
        case .failed:
            return "Failed"
        }
    }

    var browserURL: URL? {
        makeURL(host: host == RemoteServerBindMode.network.host ? "127.0.0.1" : host)
    }

    var remoteURL: URL? {
        makeURL(host: displayHost)
    }

    var remoteURLString: String {
        remoteURL?.absoluteString ?? "http://\(displayHost):\(port)/"
    }

    func start(bindMode: RemoteServerBindMode, port: Int, token: String?) {
        guard !isActive else {
            return
        }

        let trimmedToken = token?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
        self.host = bindMode.host
        self.port = port
        self.token = trimmedToken
        processID = nil
        launchCommand = ""
        logText = ""
        requestedStop = false
        state = .starting

        do {
            let launchPlan = try RemoteServerLaunchPlan.resolve()
            let process = Process()
            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()

            process.executableURL = launchPlan.executableURL
            process.arguments = launchPlan.arguments
            process.currentDirectoryURL = launchPlan.workingDirectoryURL
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            var environment = CommandRunner.baseEnvironment()
            environment["SWIFTMUX_HOST"] = bindMode.host
            environment["SWIFTMUX_PORT"] = String(port)
            if let trimmedToken {
                environment["SWIFTMUX_TOKEN"] = trimmedToken
            } else {
                environment.removeValue(forKey: "SWIFTMUX_TOKEN")
            }
            if let webRoot = launchPlan.webRootURL?.path {
                environment["SWIFTMUX_WEB_ROOT"] = webRoot
            }
            process.environment = environment

            stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in
                    self?.appendLog(data)
                }
            }

            stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                Task { @MainActor in
                    self?.appendLog(data)
                }
            }

            process.terminationHandler = { [weak self] process in
                Task { @MainActor in
                    self?.handleTermination(process)
                }
            }

            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.launchCommand = launchPlan.commandDescription

            try process.run()
            processID = process.processIdentifier

            readinessTask?.cancel()
            readinessTask = Task { [weak self] in
                await self?.waitUntilHealthy()
            }
        } catch {
            cleanupProcessReferences()
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        requestedStop = true
        readinessTask?.cancel()
        readinessTask = nil

        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil

        if process?.isRunning == true {
            process?.terminate()
        }

        cleanupProcessReferences()
        state = .stopped
    }

    func clearFailure() {
        guard case .failed = state else {
            return
        }
        state = .stopped
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        let byteCount = bytes.count
        let result = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        if result == errSecSuccess {
            return Data(bytes)
                .base64EncodedString()
                .replacingOccurrences(of: "+", with: "-")
                .replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: "")
        }

        return [
            UUID().uuidString,
            UUID().uuidString
        ].joined().replacingOccurrences(of: "-", with: "").lowercased()
    }

    private func waitUntilHealthy() async {
        for _ in 0..<40 {
            if Task.isCancelled {
                return
            }

            if await isHealthy() {
                if case .starting = state {
                    state = .running
                }
                return
            }

            try? await Task.sleep(nanoseconds: 250_000_000)
        }

        if case .starting = state, process?.isRunning == true {
            state = .running
        }
    }

    private func isHealthy() async -> Bool {
        guard process?.isRunning == true else {
            return false
        }

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/healthz"

        guard let url = components.url else {
            return false
        }

        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 0.5

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func appendLog(_ data: Data) {
        guard let text = String(data: data, encoding: .utf8), !text.isEmpty else {
            return
        }

        logText.append(text)
        if logText.count > 12_000 {
            logText = String(logText.suffix(12_000))
        }
    }

    private func handleTermination(_ terminatedProcess: Process) {
        guard processID == terminatedProcess.processIdentifier else {
            return
        }

        let exitCode = terminatedProcess.terminationStatus
        cleanupProcessReferences()

        if requestedStop {
            state = .stopped
        } else if exitCode == 0 {
            state = .stopped
        } else {
            state = .failed("SwiftMuxServer exited with status \(exitCode).")
        }
    }

    private func cleanupProcessReferences() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process?.terminationHandler = nil
        process = nil
        stdoutPipe = nil
        stderrPipe = nil
        processID = nil
        readinessTask?.cancel()
        readinessTask = nil
    }

    private var displayHost: String {
        guard host == RemoteServerBindMode.network.host else {
            return host
        }

        return Self.primaryLANIPv4Address()
            ?? ProcessInfo.processInfo.hostName.nonEmpty
            ?? "127.0.0.1"
    }

    private func makeURL(host: String) -> URL? {
        var components = URLComponents()
        components.scheme = "http"
        components.host = host
        components.port = port
        components.path = "/"
        if let token {
            components.queryItems = [
                URLQueryItem(name: "token", value: token)
            ]
        }
        return components.url
    }

    private static func primaryLANIPv4Address() -> String? {
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let firstInterface = interfaces else {
            return nil
        }
        defer { freeifaddrs(interfaces) }

        var fallbackAddress: String?
        var interface = firstInterface
        while true {
            let flags = Int32(interface.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) == IFF_UP
            let isLoopback = (flags & IFF_LOOPBACK) == IFF_LOOPBACK

            if isUp,
               !isLoopback,
               let address = interface.pointee.ifa_addr,
               address.pointee.sa_family == UInt8(AF_INET),
               let name = String(validatingUTF8: interface.pointee.ifa_name),
               let hostAddress = numericHostAddress(from: address) {
                if name == "en0" {
                    return hostAddress
                }
                fallbackAddress = fallbackAddress ?? hostAddress
            }

            guard let next = interface.pointee.ifa_next else {
                break
            }
            interface = next
        }

        return fallbackAddress
    }

    private static func numericHostAddress(from socketAddress: UnsafePointer<sockaddr>) -> String? {
        var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = getnameinfo(
            socketAddress,
            socklen_t(socketAddress.pointee.sa_len),
            &hostBuffer,
            socklen_t(hostBuffer.count),
            nil,
            0,
            NI_NUMERICHOST
        )

        guard result == 0 else {
            return nil
        }

        return String(cString: hostBuffer).nonEmpty
    }
}

private struct RemoteServerLaunchPlan {
    let executableURL: URL
    let arguments: [String]
    let workingDirectoryURL: URL?
    let webRootURL: URL?
    let commandDescription: String

    static func resolve() throws -> RemoteServerLaunchPlan {
        let fileManager = FileManager.default

        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            let bundledServer = executableDirectory.appendingPathComponent("SwiftMuxServer")
            if fileManager.isExecutableFile(atPath: bundledServer.path) {
                return RemoteServerLaunchPlan(
                    executableURL: bundledServer,
                    arguments: [],
                    workingDirectoryURL: executableDirectory,
                    webRootURL: bundledWebRoot(),
                    commandDescription: bundledServer.path
                )
            }
        }

        for root in packageRoots() {
            let debugServer = root.appendingPathComponent(".build/debug/SwiftMuxServer")
            if fileManager.isExecutableFile(atPath: debugServer.path) {
                return RemoteServerLaunchPlan(
                    executableURL: debugServer,
                    arguments: [],
                    workingDirectoryURL: root,
                    webRootURL: webRoot(in: root),
                    commandDescription: debugServer.path
                )
            }

            let archServers = [
                root.appendingPathComponent(".build/arm64-apple-macosx/debug/SwiftMuxServer"),
                root.appendingPathComponent(".build/x86_64-apple-macosx/debug/SwiftMuxServer")
            ]
            if let archServer = archServers.first(where: { fileManager.isExecutableFile(atPath: $0.path) }) {
                return RemoteServerLaunchPlan(
                    executableURL: archServer,
                    arguments: [],
                    workingDirectoryURL: root,
                    webRootURL: webRoot(in: root),
                    commandDescription: archServer.path
                )
            }
        }

        if let root = packageRoots().first {
            return RemoteServerLaunchPlan(
                executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                arguments: ["swift", "run", "SwiftMuxServer"],
                workingDirectoryURL: root,
                webRootURL: webRoot(in: root),
                commandDescription: "swift run SwiftMuxServer"
            )
        }

        throw CommandRunnerError.missingExecutable(
            "Could not find SwiftMuxServer. Build the server target or use the bundled app recipe."
        )
    }

    private static func bundledWebRoot() -> URL? {
        guard let resources = Bundle.main.resourceURL else {
            return nil
        }

        let webRoot = resources.appendingPathComponent("Web")
        return FileManager.default.fileExists(atPath: webRoot.path) ? webRoot : nil
    }

    private static func webRoot(in packageRoot: URL) -> URL? {
        let webRoot = packageRoot.appendingPathComponent("Web")
        return FileManager.default.fileExists(atPath: webRoot.path) ? webRoot : nil
    }

    private static func packageRoots() -> [URL] {
        let fileManager = FileManager.default
        let anchors = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true),
            URL(fileURLWithPath: #filePath),
            Bundle.main.bundleURL,
            Bundle.main.executableURL
        ].compactMap { $0 }

        var roots: [URL] = []
        var seen: Set<String> = []

        for anchor in anchors {
            var directory = anchor.hasDirectoryPath ? anchor : anchor.deletingLastPathComponent()
            directory = directory.standardizedFileURL

            while true {
                let manifest = directory.appendingPathComponent("Package.swift")
                if fileManager.fileExists(atPath: manifest.path) {
                    let path = directory.path
                    if seen.insert(path).inserted {
                        roots.append(directory)
                    }
                    break
                }

                let parent = directory.deletingLastPathComponent().standardizedFileURL
                if parent.path == directory.path {
                    break
                }
                directory = parent
            }
        }

        return roots
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
