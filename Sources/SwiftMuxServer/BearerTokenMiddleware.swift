import Foundation
import Hummingbird
import HummingbirdWebSocket

/// Rejects control requests whose Authorization header doesn't carry the configured bearer token.
/// The static web app shell is public because browsers cannot attach Authorization
/// headers to ordinary stylesheet/script/manifest requests. API and WebSocket routes
/// still require the bearer token.
struct BearerTokenMiddleware: RouterMiddleware {
    typealias Context = BasicWebSocketRequestContext

    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if !requiresAuthentication(path: request.uri.path) {
            return try await next(request, context)
        }

        let header = request.headers[.authorization] ?? ""
        let queryToken = request.uri.queryParameters.get("token")
        let expected = "Bearer \(token)"
        guard header == expected || queryToken == token else {
            return Response(
                status: .unauthorized,
                headers: [.wwwAuthenticate: "Bearer"]
            )
        }

        return try await next(request, context)
    }

    private func requiresAuthentication(path: String) -> Bool {
        path == "/api" ||
            path.hasPrefix("/api/") ||
            path == "/ws" ||
            path.hasPrefix("/ws/")
    }
}
