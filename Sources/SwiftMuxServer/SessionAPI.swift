import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftMuxCore

struct PeekResponse: ResponseEncodable, Codable {
    let lines: Int
    let output: String
}

enum SessionAPI {
    static func register(on router: Router<BasicWebSocketRequestContext>) {
        router.get("/healthz") { _, _ -> String in
            "ok"
        }

        router.get("/api/sessions") { _, _ -> [SessionInfo] in
            try SessionService.loadSessions()
        }

        router.get("/api/sessions/:name/peek") { request, context -> PeekResponse in
            let name = try context.parameters.require("name", as: String.self)
            let lines = request.uri.queryParameters
                .get("lines", as: Int.self) ?? 50
            let output = try SessionService.peek(name: name, lines: lines)
            return PeekResponse(lines: lines, output: output)
        }

        router.post("/api/sessions/:name/kill") { _, context -> HTTPResponse.Status in
            let name = try context.parameters.require("name", as: String.self)
            try SessionService.kill(name: name)
            return .noContent
        }
    }
}
