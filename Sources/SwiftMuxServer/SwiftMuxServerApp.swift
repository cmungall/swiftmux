import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftMuxCore

@main
struct SwiftMuxServerApp {
    static func main() async throws {
        let config = ServerConfiguration.fromEnvironment()

        let router = Router(context: BasicWebSocketRequestContext.self)

        if let token = config.bearerToken {
            router.add(middleware: BearerTokenMiddleware(token: token))
        }

        SessionAPI.register(on: router)
        TerminalWebSocket.register(on: router)

        // Serve the PWA from Web/ (relative to the working directory the
        // server is launched from — typically the repo root).
        let webRoot = config.webRoot ?? FileManager.default
            .currentDirectoryPath.appending("/Web")
        if FileManager.default.fileExists(atPath: webRoot) {
            router.add(middleware: FileMiddleware(webRoot, searchForIndexHtml: true))
        }

        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(webSocketRouter: router),
            configuration: .init(
                address: .hostname(config.host, port: config.port),
                serverName: "SwiftMuxServer"
            )
        )

        let scheme = "http"
        let authNote = config.bearerToken == nil
            ? "no auth (set SWIFTMUX_TOKEN to require Authorization: Bearer …)"
            : "bearer-token auth required"
        print("SwiftMuxServer listening on \(scheme)://\(config.host):\(config.port) — \(authNote)")
        if FileManager.default.fileExists(atPath: webRoot) {
            print("Web client mounted from \(webRoot)")
        } else {
            print("No Web client at \(webRoot) — REST/WS only")
        }

        try await app.runService()
    }
}

