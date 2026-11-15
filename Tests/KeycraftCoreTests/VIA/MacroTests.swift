import Foundation
import Testing
@testable import KeycraftCore

@Suite struct MacroTests {
    // Bytes exactly as QMK's send_string_with_delay_impl reads them.
    let spotlight: [UInt8] = [1, 2, 0xE3, 1, 1, 0x2C, 1, 3, 0xE3, 1, 4] + Array("300|".utf8) + Array("Safari".utf8) + [1, 1, 0x28, 0]

    @Test func decodesFirmwareBytes() {
        let macros = Macros.decode(spotlight + Array("hi".utf8) + [0], count: 3)
        #expect(macros[0] == [.down(0xE3), .tap(0x2C), .up(0xE3), .delay(300), .text("Safari"), .tap(0x28)])
        #expect(macros[1] == [.text("hi")])
        #expect(macros[2] == [])   // buffer ended: empty, not missing
    }

    @Test func encodeRoundTrips() {
        let macros: [[MacroStep]] = [[.down(0xE3), .tap(0x2C), .up(0xE3), .delay(300), .text("Safari"), .tap(0x28)], [], [.text("a\nb")]]
        let bytes = Macros.encode(macros)
        #expect(Array(bytes.prefix(spotlight.count)) == spotlight)
        #expect(Macros.decode(bytes, count: 3) == macros)
    }

    @Test func encodeDropsWhatFirmwareCantType() {
        #expect(Macros.encode([[.text("é€ok"), .tap(0)]]) == Array("ok".utf8) + [0])
    }

    @Test func malformedBytesDontCrash() {
        #expect(Macros.decode([1], count: 1) == [[]])
        #expect(Macros.decode([1, 9, 0x41], count: 1) == [[.text("A")]])   // unknown action skipped
        #expect(Macros.decode([1, 1, 0], count: 2) == [[], []])
        #expect(Macros.decode([1, 4, 0x35], count: 1) == [[.delay(5)]])
    }

    @Test func simplifyMakesTapsAndText() {
        // ⌘C stays a shortcut; "ls" then Enter become text and a tap.
        let recorded: [MacroStep] = [.down(0xE3), .down(0x06), .up(0x06), .up(0xE3),
                                     .down(0x0F), .up(0x0F), .down(0x16), .up(0x16), .down(0x28), .up(0x28)]
        #expect(Macros.simplify(recorded) == [.down(0xE3), .tap(0x06), .up(0xE3), .text("ls"), .tap(0x28)])
    }

    @Test func summaryReadsShortcuts() {
        let steps: [MacroStep] = [.down(0xE3), .tap(0x2C), .up(0xE3), .delay(300), .text("Safari"), .tap(0x28)]
        #expect(Macros.summary(steps) == "⌘␣, wait 300 ms, “Safari”, ↩")
        #expect(Macros.summary([]) == "Empty")
    }

    @Test func macroKeycodesHaveNames() {
        #expect(Keycode.info(0x7700).label == "M0")
        #expect(Keycode.info(0x7703).name == "Macro 3")
        let group = Keycode.catalogue(layerCount: 4, macros: ["“hi”", "Empty"]).first { $0.title == "Macros" }
        #expect(group?.keycodes.map(\.code) == [0x7700, 0x7701])
        #expect(group?.keycodes.first?.description == "“hi”")
    }

    @Test func clientWritesAndVerifies() async throws {
        let mock = MockVIADevice()
        let client = VIAClient(transport: mock)
        let macros: [[MacroStep]] = [[.text("me@example.com"), .tap(0x28)], [], [.down(0xE3), .tap(0x06), .up(0xE3)], []]
        try await client.writeMacros(macros)
        let (back, size) = try await client.readMacros()
        #expect(back == macros)
        #expect(size == MockVIADevice.macroBufferSize)
        #expect(mock.macroBytes.last == 0)
        // The in-progress marker is written before any data and cleared last.
        let sets = mock.sentReports.filter { $0[0] == VIACommand.macroSetBuffer.rawValue }
        let last = MockVIADevice.macroBufferSize - 1
        #expect(Array(sets.first![1...4]) == [UInt8(last >> 8), UInt8(last & 0xFF), 1, 0xFF])
        #expect(Array(sets.last![1...4]) == [UInt8(last >> 8), UInt8(last & 0xFF), 1, 0x00])
        #expect(sets.allSatisfy { $0[3] <= 28 })
    }

    @Test func clientRefusesMacrosThatDontFit() async {
        let client = VIAClient(transport: MockVIADevice())
        let long: [[MacroStep]] = [[.text(String(repeating: "x", count: MockVIADevice.macroBufferSize))]]
        await #expect(throws: VIAError.macrosTooLong(bytes: MockVIADevice.macroBufferSize + 1, limit: MockVIADevice.macroBufferSize - 1)) {
            try await client.writeMacros(long)
        }
    }

    @Test func oldProtocolIsRefused() async {
        let mock = MockVIADevice()
        let client = VIAClient(transport: SpyTransport(mock, reportedVersion: 10))
        await #expect(throws: VIAError.unsupportedProtocol(10)) { try await client.writeMacros([[]]) }
        #expect(!mock.sentReports.contains { $0[0] == VIACommand.macroSetBuffer.rawValue })
    }
}
