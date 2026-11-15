import Foundation
import Testing
@testable import KeycraftCore

@Suite struct KeyboardLibraryTests {
    private func emptyDir() -> URL { makeTempDirectory() }
    private let missing = URL(filePath: "/nonexistent/keycraft.zlib")

    private func bundledLibrary(userDirectory: URL? = nil) async -> KeyboardLibrary {
        await KeyboardLibrary.load(userDirectory: userDirectory ?? emptyDir(), downloadedFile: missing)
    }

    private func writeDatabase(_ builtAt: String, to url: URL, name: String) throws {
        let json = #"{"version":1,"builtAt":"\#(builtAt)","keyboards":[{"name":"\#(name)","maker":"M","vendorId":"0x4335","productId":"0x0002","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[["0,0"]]}}]}"#
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try (Data(json.utf8) as NSData).compressed(using: .zlib).write(to: url, options: .atomic)
    }

    @Test func bundledDatabaseLoadsAndFindsGH60() async throws {
        let library = await bundledLibrary()
        #expect(library.count == 2032 && library.builtAt != nil)
        let gh60 = try #require(library.definition(vendorID: 0x4335, productID: 0x0002))
        #expect(gh60.name == "GH60 Satan" && gh60.rows == 5 && gh60.cols == 14 && gh60.keys.count == 61)
        #expect(library.entries.contains { $0.id == "4335:0002" && $0.source == .bundled })
        #expect(library.definition(vendorID: 0xFFFF, productID: 0xFFFF) == nil)
    }

    @Test func everyBundledDefinitionParses() async throws {
        let library = await bundledLibrary()
        var failures: [String] = []
        for entry in library.entries {
            guard let definition = library.definition(vendorID: entry.vendorID, productID: entry.productID) else {
                failures.append("\(entry.id) \(entry.name): does not decode"); continue
            }
            if definition.keys.isEmpty { failures.append("\(entry.id) \(entry.name): no visible keys") }
        }
        print("PARSE RATE: \(library.count - failures.count)/\(library.count)")
        failures.forEach { print("PARSE FAILURE: \($0)") }
        #expect(Double(library.count - failures.count) / Double(library.count) >= 0.99)
    }

    @Test func importedDefinitionBeatsBundled() async throws {
        let user = emptyDir()
        defer { try? FileManager.default.removeItem(at: user) }
        try Data(#"{"name":"Mine","maker":"Me","vendorId":"0x4335","productId":"0x0002","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[["0,0"]]}}"#.utf8)
            .write(to: user.appending(path: "mine.json"))
        try Data(#"{"name":"New","vendorId":"0x1234","productId":"0x5678","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[["0,0"]]}}"#.utf8)
            .write(to: user.appending(path: "new.json"))
        try Data("not json".utf8).write(to: user.appending(path: "bad.json"))
        let library = await bundledLibrary(userDirectory: user)
        #expect(library.definition(vendorID: 0x4335, productID: 0x0002)?.name == "Mine")
        #expect(library.definition(vendorID: 0x1234, productID: 0x5678)?.name == "New")
        #expect(library.count == 2033)
        #expect(library.entries.filter { $0.source == .imported }.count == 2)
    }

    @Test func downloadedDatabaseWinsOnlyWhenNewer() async throws {
        let dir = emptyDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let newer = dir.appending(path: "newer.zlib"), older = dir.appending(path: "older.zlib")
        try writeDatabase("2999-01-01T00:00:00Z", to: newer, name: "From Download")
        try writeDatabase("2000-01-01T00:00:00Z", to: older, name: "Stale Download")
        let user = emptyDir()
        let fromNewer = await KeyboardLibrary.load(userDirectory: user, downloadedFile: newer)
        #expect(fromNewer.count == 1 && fromNewer.entries[0].source == .downloaded)
        #expect(fromNewer.definition(vendorID: 0x4335, productID: 0x0002)?.name == "From Download")
        let fromOlder = await KeyboardLibrary.load(userDirectory: user, downloadedFile: older)
        #expect(fromOlder.count == 2032 && fromOlder.definition(vendorID: 0x4335, productID: 0x0002)?.name == "GH60 Satan")
    }
}
