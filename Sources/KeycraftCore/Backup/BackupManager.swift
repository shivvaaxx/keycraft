import Foundation
import os

/// What gets written to `<ISO8601>.json`.
public struct BackupFile: Codable, Sendable {
    public struct Device: Codable, Sendable {
        public var vendorID: Int
        public var productID: Int
        public var productName: String
        public var manufacturer: String
        public var serial: String?
    }
    public var appVersion: String
    public var createdAt: String            // ISO 8601
    public var device: Device
    public var items: [BackupEntry]
    public var proceededWithoutFullBackup: Bool
    public var missingItemIDs: [String]     // important items that were not saved

    public var keymapData: Data? { items.first { $0.id == "keymap" && $0.status == .saved }?.data }
}

public struct BackupRecord: Sendable, Identifiable {
    public let url: URL
    public let file: BackupFile
    public var id: URL { url }
}

public struct BackupManager: Sendable {
    public struct Outcome: Sendable {
        public let url: URL
        public let proceed: Bool
        public let missing: [BackupEntry]
    }

    public let directory: URL
    public let appVersion: String
    private static let log = Logger(subsystem: "app.keycraft.Keycraft", category: "backup")

    public static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Keycraft/Backups", directoryHint: .isDirectory)
    }

    public init(directory: URL = BackupManager.defaultDirectory, appVersion: String = "0.1.0") {
        self.directory = directory
        self.appVersion = appVersion
    }

    /// Tries EVERY item (never refuses), saves the file regardless, and asks `confirm` only if an
    /// important item was not saved. `proceed == false` means the caller must not send its write.
    public func backUp(items: [BackupItem], device: HIDDeviceInfo,
                       confirm: @Sendable ([BackupEntry]) async -> Bool) async throws -> Outcome {
        var entries: [BackupEntry] = []
        for item in items {
            let result: BackupResult
            do {
                if let data = try await item.read() { result = .saved(data) } else { result = .notSupported(item.notSupportedReason) }
            } catch {
                result = .failed(error.localizedDescription)
            }
            let entry = BackupEntry(item: item, result: result)
            if entry.status != .saved && item.importance == .optional {
                Self.log.info("optional backup item \(item.id, privacy: .public) not saved: \(entry.reason ?? "", privacy: .public)")
            }
            entries.append(entry)
        }

        let missing = entries.filter { $0.importance == .important && $0.status != .saved }
        let proceed = missing.isEmpty ? true : await confirm(missing)
        let now = Date()
        let file = BackupFile(
            appVersion: appVersion,
            createdAt: ISO8601DateFormatter().string(from: now),
            device: .init(vendorID: device.vendorID, productID: device.productID, productName: device.productName,
                          manufacturer: device.manufacturer, serial: device.serial),
            items: entries,
            proceededWithoutFullBackup: proceed && !missing.isEmpty,
            missingItemIDs: missing.map(\.id))

        let folder = directory.appending(path: Self.folderName(device), directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appending(path: Self.fileName(now))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(file).write(to: url, options: .atomic)
        return Outcome(url: url, proceed: proceed, missing: missing)
    }

    /// Newest first.
    public func list(device: HIDDeviceInfo) -> [BackupRecord] {
        let folder = directory.appending(path: Self.folderName(device), directoryHint: .isDirectory)
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
            .compactMap { url in
                (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(BackupFile.self, from: $0) }
                    .map { BackupRecord(url: url, file: $0) }
            }
    }

    // `<vid>-<pid>-<serial|"noserial">`
    static func folderName(_ d: HIDDeviceInfo) -> String {
        let serial = (d.serial?.isEmpty == false ? d.serial! : "noserial")
            .map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "_" }.joined()
        return String(format: "%04x-%04x-", d.vendorID, d.productID) + serial
    }

    // ISO 8601 with fractional seconds; ":" becomes "-" so the name is safe in Finder.
    static func fileName(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date).replacingOccurrences(of: ":", with: "-") + ".json"
    }
}
