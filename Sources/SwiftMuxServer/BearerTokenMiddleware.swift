import Foundation
import Hummingbird
import HummingbirdWebSocket

/// Rejects requests whose Authorization header doesn't carry the configured bearer token.
/// Healthz is exempted so external monitors can probe without credentials.
struct BearerTokenMiddleware: RouterMiddleware {
    typealias Context = BasicWebSocketRequestContext

    let token: String

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        if request.uri.path == "/healthz" {
            return try await next(request, context)
        }

        let header = request.headers[.authorization] ?? ""
        let expected = "Bearer \(token)"
        guard header == expected else {
            return Response(
                status: .unauthorized,
                headers: [.wwwAuthenticate: "Bearer"]
            )
        }

        return try await next(request, context)
    }
}
