import CryptoKit
import Foundation

public enum LibraryUpdateError: LocalizedError, Equatable {
    case notConfigured, notHTTPS, badManifest, http(Int), checksumMismatch, invalidDatabase

    public var errorDescription: String? {
        switch self {
        case .notConfigured: "Keyboard updates aren't set up in this build of Keycraft."
        case .notHTTPS: "The update server didn't use a secure connection, so Keycraft ignored it."
        case .badManifest: "The update server sent something Keycraft doesn't understand."
        case .http(let status): "The update server answered with an error (\(status))."
        case .checksumMismatch: "The downloaded library didn't match its checksum, so Keycraft kept the current one."
        case .invalidDatabase: "The downloaded library couldn't be read, so Keycraft kept the current one."
        }
    }
}

/// Checks `<base>/manifest.json` and, if it names a newer library, downloads it, verifies its SHA-256 and saves it
/// atomically where `KeyboardLibrary` looks for the downloaded database. HTTPS only (including redirects).
public struct LibraryUpdater: Sendable {
    public enum Outcome: Sendable, Equatable { case upToDate, updated(count: Int, builtAt: Date) }

    private struct Manifest: Decodable { let builtAt: String; let sha256: String; let url: URL; let count: Int? }

    private let baseURL: URL?
    private let session: URLSession
    private let destination: URL

    public init(baseURL: URL? = KeycraftConfig.libraryBaseURL, session: URLSession = .shared,
                destination: URL = KeyboardLibrary.defaultDownloadedFile) {
        (self.baseURL, self.session, self.destination) = (baseURL, session, destination)
    }

    public var isConfigured: Bool { baseURL != nil }

    /// `activeBuiltAt` is the build date of the library in use now; only a strictly newer one is downloaded.
    public func check(activeBuiltAt: Date?) async throws -> Outcome {
        guard let baseURL else { throw LibraryUpdateError.notConfigured }
        let manifestData = try await fetch(baseURL.appending(path: "manifest.json"))
        guard let manifest = try? JSONDecoder().decode(Manifest.self, from: manifestData),
              let builtAt = try? Date(manifest.builtAt, strategy: .iso8601) else { throw LibraryUpdateError.badManifest }
        guard manifest.url.scheme == "https" else { throw LibraryUpdateError.notHTTPS }
        guard builtAt > activeBuiltAt ?? .distantPast else { return .upToDate }

        let data = try await fetch(manifest.url)
        guard SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == manifest.sha256.lowercased() else {
            throw LibraryUpdateError.checksumMismatch
        }
        guard let info = KeyboardLibrary.inspect(data) else { throw LibraryUpdateError.invalidDatabase }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        return .updated(count: info.count, builtAt: info.builtAt ?? builtAt)
    }

    private func fetch(_ url: URL) async throws -> Data {
        guard url.scheme == "https" else { throw LibraryUpdateError.notHTTPS }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await session.data(for: request, delegate: HTTPSOnlyRedirects())
        guard let http = response as? HTTPURLResponse else { throw LibraryUpdateError.badManifest }
        guard http.statusCode == 200 else { throw LibraryUpdateError.http(http.statusCode) }
        return data
    }
}

/// GitHub release assets redirect to another host; following that is fine as long as it stays on HTTPS.
private final class HTTPSOnlyRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest) async -> URLRequest? {
        request.url?.scheme == "https" ? request : nil
    }
}
