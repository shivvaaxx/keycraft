import Foundation

public struct LibraryEntry: Sendable, Hashable, Identifiable {
    public enum Source: Sendable { case bundled, downloaded, imported }
    public let name: String
    public let maker: String
    public let vendorID: Int
    public let productID: Int
    public let source: Source
    public var id: String { String(format: "%04X:%04X", vendorID, productID) }
}

/// Every keyboard definition Keycraft knows. Priority for one vid:pid: user-imported, then the downloaded
/// database (only if newer than the bundled one), then the bundled database. Immutable once loaded; JSON is
/// kept per entry and decoded to a `VIADefinition` only when asked for.
public final class KeyboardLibrary: Sendable {
    public let entries: [LibraryEntry]
    public let builtAt: Date?
    public var count: Int { entries.count }
    private let raw: [Int: Data]
    private let entryByID: [Int: LibraryEntry]
    private let databaseIDs: Set<Int>

    /// `KEYCRAFT_LIBRARY_FILE` redirects the downloaded library (used to test updates without touching ~/Library).
    public static var defaultDownloadedFile: URL {
        ProcessInfo.processInfo.environment["KEYCRAFT_LIBRARY_FILE"].map { URL(filePath: $0) }
            ?? URL.applicationSupportDirectory.appending(path: "Keycraft/Library/via-keyboards.zlib")
    }
    public static var bundledFile: URL? {
        Bundle.module.url(forResource: "via-keyboards", withExtension: "zlib", subdirectory: "KeyboardDatabase")
            ?? Bundle.module.url(forResource: "KeyboardDatabase", withExtension: nil)?.appending(path: "via-keyboards.zlib")
    }

    private static func key(_ vendorID: Int, _ productID: Int) -> Int { vendorID << 16 | productID }

    public func entry(vendorID: Int, productID: Int) -> LibraryEntry? { entryByID[Self.key(vendorID, productID)] }

    /// True if the bundled or downloaded database (not just a user-imported file) has this keyboard.
    public func databaseContains(vendorID: Int, productID: Int) -> Bool { databaseIDs.contains(Self.key(vendorID, productID)) }

    /// The stored definition JSON exactly as loaded (used to share a user-imported layout).
    public func rawDefinition(vendorID: Int, productID: Int) -> Data? { raw[Self.key(vendorID, productID)] }

    public func definition(vendorID: Int, productID: Int) -> VIADefinition? {
        raw[Self.key(vendorID, productID)].flatMap { try? VIADefinition(data: $0) }
    }

    /// Reads and parses everything off the calling thread.
    public static func load(userDirectory: URL = VIADefinition.defaultUserDirectory,
                            downloadedFile: URL = defaultDownloadedFile,
                            bundledFile: URL? = KeyboardLibrary.bundledFile) async -> KeyboardLibrary {
        await Task.detached(priority: .userInitiated) {
            KeyboardLibrary(userDirectory: userDirectory, downloadedFile: downloadedFile, bundledFile: bundledFile)
        }.value
    }

    init(userDirectory: URL, downloadedFile: URL, bundledFile: URL?) {
        var database = bundledFile.flatMap { Self.readDatabase($0, source: .bundled) }
        if let downloaded = Self.readDatabase(downloadedFile, source: .downloaded),
           downloaded.builtAt ?? .distantPast > database?.builtAt ?? .distantPast { database = downloaded }
        var byID = database?.byID ?? [:]
        databaseIDs = Set(byID.keys)
        for file in (try? FileManager.default.contentsOfDirectory(at: userDirectory, includingPropertiesForKeys: nil)) ?? []
        where file.pathExtension == "json" {
            guard let data = try? Data(contentsOf: file), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let item = Self.item(object, source: .imported, data: data) else { continue }
            byID[item.key] = item.value
        }
        entries = byID.values.map(\.entry).sorted { ($0.maker, $0.name) < ($1.maker, $1.name) }
        raw = byID.mapValues(\.data)
        entryByID = byID.mapValues(\.entry)
        builtAt = database?.builtAt
    }

    private typealias Item = (entry: LibraryEntry, data: Data)

    private static func item(_ object: [String: Any], source: LibraryEntry.Source, data: Data? = nil) -> (key: Int, value: Item)? {
        func hex(_ k: String) -> Int? {
            guard let s = (object[k] as? String)?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
            return Int(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16)
        }
        guard let name = object["name"] as? String, let vid = hex("vendorId"), let pid = hex("productId"),
              let json = data ?? (try? JSONSerialization.data(withJSONObject: object)) else { return nil }
        let entry = LibraryEntry(name: name, maker: object["maker"] as? String ?? "", vendorID: vid, productID: pid, source: source)
        return (key(vid, pid), (entry, json))
    }

    /// Validates downloaded database bytes (raw-deflate JSON with a `keyboards` list) before they are saved.
    static func inspect(_ compressed: Data) -> (count: Int, builtAt: Date?)? {
        parseDatabase(compressed, source: .downloaded).map { ($0.byID.count, $0.builtAt) }
    }

    private static func readDatabase(_ file: URL, source: LibraryEntry.Source) -> (byID: [Int: Item], builtAt: Date?)? {
        (try? Data(contentsOf: file)).flatMap { parseDatabase($0, source: source) }
    }

    private static func parseDatabase(_ compressed: Data, source: LibraryEntry.Source) -> (byID: [Int: Item], builtAt: Date?)? {
        guard let json = try? (compressed as NSData).decompressed(using: .zlib) as Data,
              let root = try? JSONSerialization.jsonObject(with: json) as? [String: Any],
              let keyboards = root["keyboards"] as? [[String: Any]] else { return nil }
        var byID: [Int: Item] = [:]
        for keyboard in keyboards { if let item = item(keyboard, source: source) { byID[item.key] = item.value } }
        let builtAt = (root["builtAt"] as? String).flatMap { try? Date($0, strategy: .iso8601) }
        return (byID, builtAt)
    }
}
