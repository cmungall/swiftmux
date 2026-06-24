import Foundation
import Security

/// Generates URL-safe random bearer tokens for the remote-control server.
public enum SecureToken {
    /// Returns a base64url-encoded random token. 24 bytes ≈ 192 bits of entropy.
    public static func generate(byteCount: Int = 24) -> String {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        let status = bytes.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, byteCount, buffer.baseAddress!)
        }
        if status == errSecSuccess {
            return Data(bytes).base64URLEncodedString()
        }

        // SecRandomCopyBytes is not expected to fail on macOS; fall back to UUID entropy.
        return (UUID().uuidString + UUID().uuidString)
            .replacingOccurrences(of: "-", with: "")
            .lowercased()
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
