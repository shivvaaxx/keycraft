import Testing
@testable import KeycraftCore

@Suite struct MockVIADeviceTests {
    let mock = MockVIADevice()

    private func ask(_ bytes: [UInt8]) async throws -> [UInt8] {
        try await mock.send(bytes + [UInt8](repeating: 0, count: 32 - bytes.count), timeout: .milliseconds(500))
    }

    @Test func identity() {
        #expect(mock.info.vendorID == 0x4335 && mock.info.productID == 0x0002)
        #expect(mock.info.productName == "Demo Keyboard (GH60 Satan)")
    }

    @Test func echoesArgumentsLikeFirmware() async throws {
        let r = try await ask([0x04, 0x00, 0x02, 0x01])
        #expect(Array(r[0..<4]) == [0x04, 0x00, 0x02, 0x01])
        #expect(r[4] == 0x00 && r[5] == 0x04)       // (2,1) on layer 0 is A
    }

    @Test func unknownCommandAnswersFF() async throws {
        #expect(try await ask([0x14])[0] == 0xFF)    // encoder: not implemented
        #expect(try await ask([0x07])[0] == 0xFF)    // custom set: not implemented
    }

    @Test func outOfRangeRequestsAnswerFFInsteadOfTrapping() async throws {
        #expect(try await ask([0x12, 0x02, 0x30, 28])[0] == 0xFF)   // offset 560
        #expect(try await ask([0x12, 0x00, 0x00, 29])[0] == 0xFF)   // size > 28
        #expect(try await ask([0x04, 9, 0, 0])[0] == 0xFF)          // layer 9
    }

    @Test func faultsAreInjectable() async throws {
        mock.failCommands = [0x11]
        await #expect(throws: HIDError.timeout) { _ = try await ask([0x11]) }
        #expect(try await ask([0x01])[2] == 0x0C)
    }

    @Test func rejectsWrongReportSize() async throws {
        await #expect(throws: HIDError.invalidReportSize(3)) { _ = try await mock.send([1, 2, 3], timeout: .seconds(1)) }
    }

    @Test func emulatesAnyDefinition() async throws {
        let def = try VIADefinition(data: fixture("v3_keychron_q1_v2_ansi.json"))
        let q1 = MockVIADevice(definition: def)
        #expect(q1.info.vendorID == 0x3434 && q1.info.productID == 0x0106 && q1.info.productName == "Keychron Q1V2 ANSI")
        let client = VIAClient(transport: q1)
        let keymap = try await client.readKeymap(layers: 4, rows: 6, cols: 16)
        #expect(keymap.count == 4 && keymap.allSatisfy { $0.count == 96 })
        let key = def.keys[0]
        #expect(keymap[0][key.row * 16 + key.col] == 0x04)                // first visible key = KC_A
        #expect(keymap[0].filter { $0 != 0 }.count == def.keys.count)    // every visible key got a code, nothing else did
        #expect(keymap[1].allSatisfy { $0 == Keycode.transparent })
        try await client.setKeycode(layer: 0, row: 0, col: 0, keycode: 0x05)
        #expect(try await client.keycode(layer: 0, row: 0, col: 0) == 0x05)
        // out-of-range for this matrix but inside the GH60 one stays refused
        #expect(try await q1.send([0x04, 0, 6, 0] + [UInt8](repeating: 0, count: 28), timeout: .seconds(1))[0] == 0xFF)
    }
}
