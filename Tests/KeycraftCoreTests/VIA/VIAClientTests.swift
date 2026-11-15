import Foundation
import Testing
@testable import KeycraftCore

@Suite struct VIAClientTests {
    let mock = MockVIADevice()

    @Test func protocolVersionAndLayerCount() async throws {
        let client = VIAClient(transport: mock)
        #expect(try await client.protocolVersion() == 0x000C)
        #expect(try await client.layerCount() == 4)
    }

    @Test func layerCountIsAssumedBelowBeta() async throws {
        let client = VIAClient(transport: SpyTransport(mock, reportedVersion: 7))
        #expect(try await client.layerCount() == 4)
        #expect(!mock.sentReports.contains { $0[0] == VIACommand.getLayerCount.rawValue })
    }

    @Test func fullKeymapReadMatchesMock() async throws {
        let client = VIAClient(transport: mock)
        let keymap = try await client.readKeymap(layers: 4, rows: 5, cols: 14)
        #expect(keymap.count == 4)
        #expect(keymap.allSatisfy { $0.count == 70 })
        let bytes = mock.keymapBytes
        for layer in 0..<4 { for i in 0..<70 {
            let o = (layer * 70 + i) * 2
            #expect(keymap[layer][i] == UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1]))
        } }
        #expect(keymap[0][2 * 14 + 1] == 0x04)          // matrix (2,1) = A
        #expect(keymap[3].allSatisfy { $0 == 0x01 })    // upper layers transparent
        // 560 bytes in <=28-byte chunks, offsets big-endian
        let gets = mock.sentReports.filter { $0[0] == VIACommand.keymapGetBuffer.rawValue }
        #expect(gets.count == 20 && gets.allSatisfy { $0[3] <= 28 })
    }

    @Test func keymapReadAtProtocolSevenUsesPerKeyReads() async throws {
        let client = VIAClient(transport: SpyTransport(mock, reportedVersion: 7))
        let bytes = try await client.readKeymapBytes(layers: 4, rows: 5, cols: 14)
        #expect(bytes == mock.keymapBytes)
        #expect(!mock.sentReports.contains { $0[0] == VIACommand.keymapGetBuffer.rawValue })
    }

    @Test func partialLastChunkIsClamped() async throws {
        let client = VIAClient(transport: mock)
        let buffer = try await client.readMacroBuffer(size: 256) // 9 x 28 + 4
        #expect(buffer.count == 256)
        let last = try #require(mock.sentReports.last)
        #expect(last[3] == 4)
    }

    @Test func setKeycodeWritesAndVerifies() async throws {
        let client = VIAClient(transport: mock)
        try await client.setKeycode(layer: 1, row: 2, col: 1, keycode: Keycode.momentary(1))
        #expect(try await client.keycode(layer: 1, row: 2, col: 1) == 0x5221)
        let o = (70 + 2 * 14 + 1) * 2
        #expect(Array(mock.keymapBytes[o...o + 1]) == [0x52, 0x21])
    }

    @Test func setKeycodeVerifyFailure() async throws {
        let client = VIAClient(transport: SpyTransport(mock, dropWrites: true))
        await #expect(throws: VIAError.verifyFailed(expected: 0x0005, actual: 0x0001)) {
            try await client.setKeycode(layer: 1, row: 0, col: 0, keycode: 0x05)
        }
    }

    @Test func echoMismatchIsBadResponse() async throws {
        mock.corruptEcho = true
        let client = VIAClient(transport: mock)
        await #expect(throws: VIAError.badResponse(command: 0x04)) {
            _ = try await client.keycode(layer: 0, row: 0, col: 0)
        }
    }

    @Test func unhandledCommandIsReportedBeforeEchoCheck() async throws {
        let client = VIAClient(transport: mock)
        await #expect(throws: VIAError.unhandled(command: 0x02)) {
            _ = try await client.request(.getKeyboardValue, [0x01], isRead: true)
        }
    }

    @Test func readsRetryOnceOnTimeout() async throws {
        mock.failCommands = [VIACommand.getKeycode.rawValue]
        let client = VIAClient(transport: mock)
        await #expect(throws: HIDError.timeout) { _ = try await client.keycode(layer: 0, row: 0, col: 0) }
        #expect(mock.sentReports.filter { $0[0] == 0x04 }.count == 2)
    }

    @Test func writesNeverRetry() async throws {
        mock.failCommands = [VIACommand.setKeycode.rawValue]
        let client = VIAClient(transport: mock)
        await #expect(throws: HIDError.timeout) { try await client.setKeycode(layer: 0, row: 0, col: 0, keycode: 5) }
        #expect(mock.sentReports.filter { $0[0] == 0x05 }.count == 1)
    }

    @Test func destructiveCommandsAreRefused() async throws {
        let client = VIAClient(transport: mock)
        for command in [VIACommand.keymapReset, .eepromReset, .bootloaderJump, .macroReset] {
            await #expect(throws: VIAError.forbiddenCommand(command.rawValue)) {
                _ = try await client.request(command, isRead: false)
            }
        }
        #expect(mock.sentReports.isEmpty)
    }

    @Test func requestsNeverOverlap() async throws {
        let spy = SpyTransport(mock, delay: .milliseconds(2))
        let client = VIAClient(transport: spy)
        try await withThrowingTaskGroup(of: UInt16.self) { group in
            for col in 0..<14 { group.addTask { try await client.keycode(layer: 0, row: 0, col: col) } }
            for try await _ in group {}
        }
        #expect(spy.maxInFlight == 1)
    }

    @Test func restoreWritesAndVerifies() async throws {
        let client = VIAClient(transport: mock)
        var edited = mock.keymapBytes
        edited[0] = 0x00; edited[1] = 0x2A // layer 0 (0,0) -> Backspace
        edited[edited.count - 1] = 0x04    // last byte of last layer
        try await client.writeKeymapBytes(edited, layers: 4, rows: 5, cols: 14)
        #expect(mock.keymapBytes == edited)
        await #expect(throws: VIAError.invalidKeymapSize(expected: 560, actual: 3)) {
            try await client.writeKeymapBytes([1, 2, 3], layers: 4, rows: 5, cols: 14)
        }
    }

    @Test func restoreDetectsFailedWrite() async throws {
        // A transport that acknowledges set_buffer but drops it.
        final class DropBuffer: HIDTransport {
            let base: MockVIADevice
            var info: HIDDeviceInfo { base.info }
            init(_ base: MockVIADevice) { self.base = base }
            func send(_ report: [UInt8], timeout: Duration) async throws -> [UInt8] {
                report[0] == VIACommand.keymapSetBuffer.rawValue ? report : try await base.send(report, timeout: timeout)
            }
            func close() {}
        }
        let client = VIAClient(transport: DropBuffer(mock))
        var edited = mock.keymapBytes
        edited[1] = 0x2A
        await #expect(throws: VIAError.verifyFailed(expected: 0x002A, actual: 0x0029)) {
            try await client.writeKeymapBytes(edited, layers: 4, rows: 5, cols: 14)
        }
    }
}
