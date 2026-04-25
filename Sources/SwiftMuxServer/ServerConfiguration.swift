import Foundation

struct ServerConfiguration: Sendable {
    var host: String
    var port: Int
    var bearerToken: String?

    static func fromEnvironment() -> ServerConfiguration {
        let env = ProcessInfo.processInfo.environment
        return ServerConfiguration(
            host: env["SWIFTMUX_HOST"] ?? "127.0.0.1",
            port: Int(env["SWIFTMUX_PORT"] ?? "") ?? 8421,
            bearerToken: env["SWIFTMUX_TOKEN"]?.nonEmpty
        )
    }
}

private extension String {
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
