import Foundation
import HTTPTypes
import Hummingbird
import HummingbirdWebSocket

/// Blocks cross-site requests to the control endpoints by validating the `Origin`
/// header. Browsers always attach an `Origin` to WebSocket handshakes and to
/// cross-origin `fetch`/XHR, so a request whose `Origin` does not match the
/// server's own host (or a loopback address) is a cross-site attempt and is
/// rejected. This stops a malicious web page from driving the victim's terminal
/// through their browser (cross-site WebSocket hijacking / CSRF), independently
/// of the bearer token.
///
/// Requests with no `Origin` header (native clients, curl, health checks) are
/// allowed through — the cross-site threat is browser-only, and those carry an
/// `Origin`.
struct OriginValidationMiddleware: RouterMiddleware {
    typealias Context = BasicWebSocketRequestContext

    func handle(
        _ request: Request,
        context: Context,
        next: (Request, Context) async throws -> Response
    ) async throws -> Response {
        guard requiresOriginCheck(path: request.uri.path) else {
            return try await next(request, context)
        }

        if let origin = request.headers[.origin], !origin.isEmpty {
            // `:authority` carries the Host value (swift-http-types marks `.host` unavailable).
            guard originIsAllowed(origin, host: request.head.authority) else {
                return Response(status: .forbidden)
            }
        }

        return try await next(request, context)
    }

    private func requiresOriginCheck(path: String) -> Bool {
        path == "/api" || path.hasPrefix("/api/") ||
            path == "/ws" || path.hasPrefix("/ws/")
    }

    /// Allows the request when the `Origin` is a loopback address or when its
    /// host:port matches the request's own `Host` header (same-origin).
    private func originIsAllowed(_ origin: String, host: String?) -> Bool {
        guard let originAuthority = authority(fromOrigin: origin) else {
            return false
        }
        if isLoopbackHost(originAuthority.host) {
            return true
        }
        guard let host, !host.isEmpty else {
            return false
        }
        let requestAuthority = splitAuthority(host)
        return originAuthority.host.caseInsensitiveCompare(requestAuthority.host) == .orderedSame
            && originAuthority.port == requestAuthority.port
    }

    /// Parses an origin like `http://127.0.0.1:8421` into host and port.
    private func authority(fromOrigin origin: String) -> (host: String, port: Int?)? {
        guard let components = URLComponents(string: origin), let host = components.host else {
            return nil
        }
        return (host, components.port)
    }

    /// Parses a `Host` header value like `127.0.0.1:8421`, `example.local`, or
    /// `[::1]:8421` into host and port.
    private func splitAuthority(_ value: String) -> (host: String, port: Int?) {
        if value.hasPrefix("["), let close = value.firstIndex(of: "]") {
            let host = String(value[value.index(after: value.startIndex)..<close])
            let rest = value[value.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }

        let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        if parts.count == 2 {
            return (String(parts[0]), Int(parts[1]))
        }
        return (value, nil)
    }

    private func isLoopbackHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower == "localhost" || lower == "127.0.0.1" || lower == "::1"
    }
}
