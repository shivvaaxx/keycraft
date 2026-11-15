import Foundation
import os
import Testing
@testable import KeycraftCore

@Suite struct BackupManagerTests {
    let dir = makeTempDirectory()
    var manager: BackupManager { BackupManager(directory: dir, appVersion: "9.9") }
    let device = MockVIADevice().info

    private func synthetic(important: Bool = true, result: Result<Data?, any Error> = .success(Data([1, 2, 3]))) -> BackupItem {
        BackupItem(id: "x", name: "X", importance: important ? .important : .optional) { try result.get() }
    }

    private func decode(_ url: URL) throws -> BackupFile {
        try JSONDecoder().decode(BackupFile.self, from: Data(contentsOf: url))
    }

    @Test func allSavedMeansNoWarning() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let asked = OSAllocatedUnfairLock(initialState: false)
        let outcome = try await manager.backUp(items: [synthetic(), synthetic(important: false)], device: device) { _ in
            asked.withLock { $0 = true }; return false
        }
        #expect(!asked.withLock { $0 } && outcome.proceed && outcome.missing.isEmpty)
        let file = try decode(outcome.url)
        #expect(!file.proceededWithoutFullBackup && file.appVersion == "9.9" && file.items.count == 2)
        #expect(file.items[0].status == .saved && file.items[0].data == Data([1, 2, 3]))
        #expect(outcome.url.deletingLastPathComponent().lastPathComponent == "4335-0002-noserial")
    }

    @Test func failingMacrosWarnsAboutMacrosAndFirmware() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let mock = MockVIADevice()
        mock.failCommands = [VIACommand.macroGetCount.rawValue]
        let items = VIAClient(transport: mock).backupItems(layers: 4, rows: 5, cols: 14)
        let asked = OSAllocatedUnfairLock(initialState: [BackupEntry]())
        let outcome = try await manager.backUp(items: items, device: device) { missing in
            asked.withLock { $0 = missing }; return true
        }
        let missing = asked.withLock { $0 }
        #expect(missing.map(\.id) == ["macros", "firmware"])
        #expect(missing[0].status == .failed && missing[0].reason?.isEmpty == false)
        #expect(missing[1].status == .notSupported && missing[1].reason == "VIA keyboards can't read their firmware back over USB")

        // Proceeding writes the file with the flag + missing ids; the keymap was still saved; lighting (optional) is not a prompt item.
        #expect(outcome.proceed)
        let file = try decode(outcome.url)
        #expect(file.proceededWithoutFullBackup && file.missingItemIDs == ["macros", "firmware"])
        #expect(file.items.map(\.id) == ["keymap", "macros", "firmware", "lighting"])
        #expect(file.items.map(\.status) == [.saved, .failed, .notSupported, .notSupported])
        #expect(file.keymapData == Data(mock.keymapBytes))
    }

    @Test func cancelStillSavesTheBackupButDoesNotProceed() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = VIAClient(transport: MockVIADevice()).backupItems(layers: 4, rows: 5, cols: 14)
        let outcome = try await manager.backUp(items: items, device: device) { _ in false }
        #expect(!outcome.proceed)
        let file = try decode(outcome.url)
        #expect(!file.proceededWithoutFullBackup && file.missingItemIDs == ["firmware"])
    }

    @Test func macrosAreBackedUpWithHeader() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        let items = VIAClient(transport: MockVIADevice()).backupItems(layers: 4, rows: 5, cols: 14)
        let outcome = try await manager.backUp(items: items, device: device) { _ in true }
        let macros = try #require(try decode(outcome.url).items.first { $0.id == "macros" }?.data)
        #expect(macros.count == 3 + 256 && Array(macros.prefix(3)) == [4, 0x01, 0x00])
    }

    @Test func optionalFailureOrThrowDoesNotPrompt() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Boom: Error {}
        let outcome = try await manager.backUp(items: [synthetic(important: false, result: .failure(Boom())),
                                                        synthetic(important: false, result: .success(nil))],
                                               device: device) { _ in Issue.record("must not prompt"); return false }
        #expect(outcome.proceed && outcome.missing.isEmpty)
        #expect(try decode(outcome.url).items.map(\.status) == [.failed, .notSupported])
    }

    @Test func importantThrowIsRecordedAsFailedNotRefused() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        struct Boom: Error {}
        let outcome = try await manager.backUp(items: [synthetic(result: .failure(Boom()))], device: device) { _ in true }
        #expect(outcome.missing.map(\.id) == ["x"] && outcome.proceed)
    }

    @Test func listReturnsNewestFirstAndSkipsOtherDevices() async throws {
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try await manager.backUp(items: [synthetic()], device: device) { _ in true }
        try await Task.sleep(for: .milliseconds(20))
        _ = try await manager.backUp(items: [synthetic(), synthetic()], device: device) { _ in true }
        var other = device; other.vendorID = 0x1; other.serial = "AB/12"
        _ = try await manager.backUp(items: [synthetic()], device: other) { _ in true }
        let records = manager.list(device: device)
        #expect(records.map(\.file.items.count) == [2, 1])
        #expect(manager.list(device: other).count == 1)
        #expect(BackupManager.folderName(other) == "0001-0002-AB_12")
    }
}
