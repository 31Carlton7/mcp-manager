import Foundation
import CryptoKit

extension Data {
    /// base64url without padding (RFC 4648 §5) — the encoding every OAuth extension uses.
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

/// Proof Key for Code Exchange (RFC 7636), S256 only.
public enum PKCE {
    /// 32 random bytes as base64url — 43 characters, inside the RFC's 43…128 range and made only
    /// of unreserved characters.
    public static func verifier() -> String { randomBytes(32).base64URLEncodedString() }

    public static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URLEncodedString()
    }

    /// Single-use CSRF value tying an authorization redirect back to the request that started it.
    public static func state() -> String { randomBytes(32).base64URLEncodedString() }

    static func randomBytes(_ count: Int) -> Data {
        SymmetricKey(size: .init(bitCount: count * 8)).withUnsafeBytes { Data($0) }
    }
}
