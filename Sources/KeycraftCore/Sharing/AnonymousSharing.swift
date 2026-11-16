import Foundation

/// Shares a keyboard definition without a GitHub account: the layout goes to Thistleware's share endpoint, which checks
/// it with the library's rules and opens the pull request under its own bot account.
public struct AnonymousSharing: Sendable {
    private let endpoint: URL
    private let session: URLSession
    private let appVersion: String

    /// Nil when the build has no share endpoint.
    public init?(endpoint: URL? = KeycraftConfig.shareEndpoint, session: URLSession = .shared, appVersion: String = "dev") {
        guard let endpoint else { return nil }
        (self.endpoint, self.session, self.appVersion) = (endpoint, session, appVersion)
    }

    /// The JSON body: the layout file's text (committed as is), the name, the maker and the USB ids.
    static func body(for submission: Submission, appVersion: String) throws -> Data {
        let fields: [String: Any] = [
            "name": submission.name,
            "maker": submission.maker,
            "vendorId": submission.vendorID,
            "productId": submission.productID,
            "definition": String(decoding: submission.json, as: UTF8.self),
            "appVersion": appVersion,
        ]
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    /// Sends the submission; returns the pull request URL. `alreadyShared`: someone shared this keyboard before, so this
    /// file was not sent and the URL is their pull request, still waiting for review.
    public func share(_ submission: Submission) async throws -> (url: URL, alreadyShared: Bool) {
        var request = URLRequest(url: endpoint, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.httpBody = try Self.body(for: submission, appVersion: appVersion)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Keycraft/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        // Only a github.com link is ever shown as "View Pull Request".
        if (200..<300).contains(status), let url = (object?["url"] as? String).flatMap(URL.init(string:)),
           url.scheme == "https", url.host() == "github.com" { return (url, object?["existing"] as? Bool ?? false) }
        throw SharingError.service(status: status, message: object?["error"] as? String ?? "The sharing service sent an unexpected answer.")
    }
}
