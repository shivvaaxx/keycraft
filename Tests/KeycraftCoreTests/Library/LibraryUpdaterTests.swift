import CryptoKit
import Foundation
import Testing
@testable import KeycraftCore

@Suite struct LibraryUpdaterTests {
    private let base = URL(string: "https://example.test/db-latest")!
    private let zlibURL = "https://example.test/db-latest/via-keyboards.zlib"

    private func database(builtAt: String) -> Data {
        let json = #"{"version":1,"builtAt":"\#(builtAt)","keyboards":[{"name":"Test Board","maker":"M","vendorId":"0x1111","productId":"0x2222","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[["0,0"]]}}]}"#
        return try! (Data(json.utf8) as NSData).compressed(using: .zlib) as Data
    }

    private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func manifest(builtAt: String, sha: String, url: String? = nil) -> [String: Any] {
        ["builtAt": builtAt, "count": 1, "sha256": sha, "url": url ?? zlibURL]
    }

    private func network(manifest: [String: Any], file: Data, manifestStatus: Int = 200) -> StubNetwork {
        let manifestReply = StubReply(manifestStatus, manifest)
        return StubNetwork { request in
            switch request.url.lastPathComponent {
            case "manifest.json": manifestReply
            case "via-keyboards.zlib": StubReply(200, data: file)
            default: StubReply(404)
            }
        }
    }

    private func destination() -> URL { makeTempDirectory().appending(path: "Library/via-keyboards.zlib") }
    private let old = try! Date("2026-01-01T00:00:00+00:00", strategy: .iso8601)

    @Test func newerLibraryIsDownloadedVerifiedAndSaved() async throws {
        let data = database(builtAt: "2026-11-15T08:00:00+00:00")
        let net = network(manifest: manifest(builtAt: "2026-11-15T08:00:00+00:00", sha: sha(data).uppercased()), file: data)
        let file = destination()
        let outcome = try await LibraryUpdater(baseURL: base, session: net.session, destination: file).check(activeBuiltAt: old)
        #expect(outcome == .updated(count: 1, builtAt: try Date("2026-11-15T08:00:00+00:00", strategy: .iso8601)))
        #expect(try Data(contentsOf: file) == data)
        #expect(net.labels == ["GET example.test/db-latest/manifest.json", "GET example.test/db-latest/via-keyboards.zlib"])
        // The next launch picks the downloaded file over the bundled one.
        let library = await KeyboardLibrary.load(userDirectory: makeTempDirectory(), downloadedFile: file, bundledFile: nil)
        #expect(library.entries.first?.source == .downloaded)
    }

    @Test func sameOrOlderLibraryIsNotDownloaded() async throws {
        let data = database(builtAt: "2026-11-15T08:00:00+00:00")
        let net = network(manifest: manifest(builtAt: "2026-11-15T08:00:00+00:00", sha: sha(data)), file: data)
        let file = destination()
        let updater = LibraryUpdater(baseURL: base, session: net.session, destination: file)
        let same = try Date("2026-11-15T08:00:00+00:00", strategy: .iso8601)
        #expect(try await updater.check(activeBuiltAt: same) == .upToDate)
        #expect(try await updater.check(activeBuiltAt: same.addingTimeInterval(3600)) == .upToDate)
        #expect(net.labels.allSatisfy { $0.hasSuffix("manifest.json") })
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func checksumMismatchKeepsTheCurrentLibrary() async throws {
        let data = database(builtAt: "2026-11-15T08:00:00+00:00")
        let net = network(manifest: manifest(builtAt: "2026-11-15T08:00:00+00:00", sha: sha(Data("other".utf8))), file: data)
        let file = destination()
        await #expect(throws: LibraryUpdateError.checksumMismatch) {
            try await LibraryUpdater(baseURL: base, session: net.session, destination: file).check(activeBuiltAt: old)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func unreadableDownloadIsRejectedEvenWithMatchingChecksum() async throws {
        let junk = Data("not a database".utf8)
        let net = network(manifest: manifest(builtAt: "2026-11-15T08:00:00+00:00", sha: sha(junk)), file: junk)
        let file = destination()
        await #expect(throws: LibraryUpdateError.invalidDatabase) {
            try await LibraryUpdater(baseURL: base, session: net.session, destination: file).check(activeBuiltAt: old)
        }
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }

    @Test func onlyHTTPSIsEverRequested() async throws {
        let data = database(builtAt: "2026-11-15T08:00:00+00:00")
        let net = network(manifest: manifest(builtAt: "2026-11-15T08:00:00+00:00", sha: sha(data), url: "http://example.test/via-keyboards.zlib"), file: data)
        await #expect(throws: LibraryUpdateError.notHTTPS) {   // the manifest names an http download
            try await LibraryUpdater(baseURL: base, session: net.session, destination: destination()).check(activeBuiltAt: old)
        }
        await #expect(throws: LibraryUpdateError.notHTTPS) {   // the base URL itself is http
            try await LibraryUpdater(baseURL: URL(string: "http://example.test")!, session: net.session, destination: destination()).check(activeBuiltAt: old)
        }
        #expect(net.labels == ["GET example.test/db-latest/manifest.json"])
    }

    @Test func notConfiguredAndServerErrorsAreReported() async throws {
        await #expect(throws: LibraryUpdateError.notConfigured) {
            try await LibraryUpdater(baseURL: nil, destination: destination()).check(activeBuiltAt: nil)
        }
        let down = network(manifest: [:], file: Data(), manifestStatus: 503)
        await #expect(throws: LibraryUpdateError.http(503)) {
            try await LibraryUpdater(baseURL: base, session: down.session, destination: destination()).check(activeBuiltAt: nil)
        }
        let garbled = network(manifest: ["builtAt": "yesterday"], file: Data())
        await #expect(throws: LibraryUpdateError.badManifest) {
            try await LibraryUpdater(baseURL: base, session: garbled.session, destination: destination()).check(activeBuiltAt: nil)
        }
    }
}
