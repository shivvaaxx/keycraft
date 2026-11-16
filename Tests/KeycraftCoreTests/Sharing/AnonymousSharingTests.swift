import Foundation
import Testing
@testable import KeycraftCore

@Suite struct AnonymousSharingTests {
    private static let endpoint = URL(string: "https://example.test/api/share-layout")!

    private func submission() throws -> Submission {
        try GitHubSharing.prepare(definition: fixture("v3_gh60_satan_satan.json"), name: "GH60 Satan", maker: "Geekhack")
    }

    private func sharing(_ net: StubNetwork) throws -> AnonymousSharing {
        try #require(AnonymousSharing(endpoint: Self.endpoint, session: net.session, appVersion: "9.9"))
    }

    /// The exact body Thistleware's functions/api/share-layout.js is tested against (tests/share-layout-request.json there).
    @Test func requestBodyMatchesTheEndpointContract() throws {
        let s = try submission()
        let body = try AnonymousSharing.body(for: s, appVersion: "9.9")
        #expect(body == (try fixture("share-layout-request.json")).trimmingTrailingNewline)
        let o = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(Set(o.keys) == ["name", "maker", "vendorId", "productId", "definition", "appVersion"])
        #expect(o["vendorId"] as? Int == 0x4335 && o["productId"] as? Int == 0x0002)
        #expect(Data((o["definition"] as? String ?? "").utf8) == s.json)   // the file is sent byte for byte, no path
    }

    @Test func sharePostsTheLayoutAndReturnsThePullRequest() async throws {
        let net = StubNetwork { _ in StubReply(201, ["url": "https://github.com/shivvaaxx/keycraft-keyboards/pull/9"]) }
        let shared = try await sharing(net).share(submission())
        #expect(shared.url.absoluteString == "https://github.com/shivvaaxx/keycraft-keyboards/pull/9" && !shared.alreadyShared)
        let r = try #require(net.requests.first)
        #expect(net.requests.count == 1 && r.method == "POST" && r.url == Self.endpoint)
        #expect(r.headers["Content-Type"] == "application/json" && r.headers["Authorization"] == nil)
    }

    @Test func anEarlierShareOfTheSameKeyboardIsReportedAsSuch() async throws {
        let net = StubNetwork { _ in StubReply(200, ["url": "https://github.com/shivvaaxx/keycraft-keyboards/pull/3", "existing": true]) }
        let shared = try await sharing(net).share(submission())
        #expect(shared.alreadyShared && shared.url.absoluteString.hasSuffix("/pull/3"))
    }

    @Test func serviceErrorsAndOddAnswersAreReported() async throws {
        let limited = StubNetwork { _ in StubReply(429, ["error": "Too many layouts shared from this network in the last hour."]) }
        await #expect(throws: SharingError.service(status: 429, message: "Too many layouts shared from this network in the last hour.")) {
            try await sharing(limited).share(submission())
        }
        let elsewhere = StubNetwork { _ in StubReply(201, ["url": "https://evil.example/pull/1"]) }
        await #expect(throws: SharingError.self) { try await sharing(elsewhere).share(submission()) }
    }

    @Test func notConfiguredMeansNoAnonymousSharing() {
        #expect(AnonymousSharing(endpoint: nil) == nil)
    }
}

private extension Data {
    var trimmingTrailingNewline: Data { last == 0x0A ? dropLast() : self }
}
