import CryptoKit
import Foundation

public struct License: Equatable, Sendable { public let product, transaction, email, issued: String }

public enum LicenseError: Error, Equatable { case malformed, badSignature, wrongProduct }

/// Offline licence-key check. Keys look like `KC1.<payload>.<signature>` (see Scripts/licence.mjs).
public enum Licensing {
    /// Production public key (raw 32 bytes, base64url). Private half never leaves the licence server.
    public static let publicKey = "Ez-u4AoMXbAiqrtAf-P73XxfTBvJIEJZeyv1t3zW-JQ"

    private struct Payload: Decodable {
        let p, t, e, i: String
    }

    public static func verify(_ key: String, publicKey: String = publicKey, product: String = "keycraft") throws -> License {
        let parts = key.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == "KC1",
              let payload = base64URL(parts[1]), let signature = base64URL(parts[2]),
              let keyBytes = base64URL(Substring(publicKey)),
              let pub = try? Curve25519.Signing.PublicKey(rawRepresentation: keyBytes)
        else { throw LicenseError.malformed }
        // The signed text is the exact "KC1.<payload>" prefix; never re-encode the JSON.
        guard pub.isValidSignature(signature, for: Data("KC1.\(parts[1])".utf8)) else { throw LicenseError.badSignature }
        guard let p = try? JSONDecoder().decode(Payload.self, from: payload) else { throw LicenseError.malformed }
        guard p.p == product else { throw LicenseError.wrongProduct }
        return License(product: p.p, transaction: p.t, email: p.e, issued: p.i)
    }

    /// base64url with or without padding.
    private static func base64URL(_ s: Substring) -> Data? {
        var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        b += String(repeating: "=", count: (4 - b.count % 4) % 4)
        return Data(base64Encoded: b)
    }
}
