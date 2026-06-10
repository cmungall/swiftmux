import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftMuxCore

@main
struct SwiftMuxServerApp {
    static func main() async throws {
        let config = ServerConfiguration.fromEnvironment()

        let router = Router(context: BasicWebSocketRequestContext.self)

        // The control surface drives live tmux sessions, so it must never run
        // unauthenticated. Use the operator-provided token, or mint a fresh one
        // for this run so the server is always behind bearer auth.
        let token = config.bearerToken ?? SecureToken.generate()
        let tokenWasGenerated = config.bearerToken == nil

        // Reject cross-site Origins on control endpoints before any work (CSWSH/CSRF).
        router.add(middleware: OriginValidationMiddleware())
        router.add(middleware: BearerTokenMiddleware(token: token))

        SessionAPI.register(on: router)
        TerminalWebSocket.register(on: router)

        // Serve the PWA from Web/ relative to the working directory the
        // server is launched from, typically the repo root.
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
        print("SwiftMuxServer listening on \(scheme)://\(config.host):\(config.port) - bearer-token auth required")
        if tokenWasGenerated {
            // No SWIFTMUX_TOKEN was provided; surface the generated token so the
            // operator can connect. Pin SWIFTMUX_TOKEN to keep a stable token.
            print("No SWIFTMUX_TOKEN set; generated one for this run:")
            print("  token: \(token)")
            print("  url:   \(scheme)://127.0.0.1:\(config.port)/?token=\(token)")
        }
        if FileManager.default.fileExists(atPath: webRoot) {
            print("Web client mounted from \(webRoot)")
        } else {
            print("No Web client at \(webRoot) - REST/WS only")
        }
        // stdout is block-buffered when piped (e.g. launched by the app); flush so
        // the generated token and startup banner are visible immediately.
        fflush(stdout)

        try await app.runService()
    }
}
