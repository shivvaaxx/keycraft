import Foundation
import Testing
@testable import KeycraftCore

@Suite struct HIDDeviceMonitorTests {
    /// Matches a usage pair nothing exposes, so no real device is ever opened by the test run. Proves the
    /// IOKit set-up/tear-down sequence (create, register, activate, cancel + cancel handler) neither
    /// crashes nor hangs, and that `stop()` finishes the event stream.
    @Test func startAndStopWithoutMatches() async throws {
        let monitor = HIDDeviceMonitor(usagePage: 0xFF5E, usage: 0x7E)
        monitor.start()
        try await Task.sleep(for: .milliseconds(300))
        monitor.stop()
        var events = 0
        for await _ in monitor.events { events += 1 }   // returns only because stop() finished the stream
        #expect(events == 0)
    }

    /// Answers nothing, like an interface that doesn't speak VIA.
    private final class Silent: HIDTransport {
        let info = HIDDeviceInfo(id: "silent", vendorID: 1, productID: 2, productName: "Silent")
        func send(_ report: [UInt8], timeout: Duration) async throws -> [UInt8] { throw HIDError.timeout }
        func close() {}
    }

    @Test func probePicksTheFirstInterfaceThatEchoesAndOnlySendsProtocolVersion() async throws {
        let mock = MockVIADevice()
        let winner = await HIDProbe.firstResponding([Silent(), mock, MockVIADevice()])
        #expect(winner === mock)
        #expect(mock.sentReports.count == 1 && mock.sentReports[0][0] == VIACommand.getProtocolVersion.rawValue)
        #expect(mock.sentReports[0].count == 32)
    }

    @Test func probeFindsNothingWhenEveryInterfaceIsSilent() async throws {
        #expect(await HIDProbe.firstResponding([Silent(), Silent()]) == nil)
        #expect(await HIDProbe.firstResponding([]) == nil)
        let corrupt = MockVIADevice()
        corrupt.corruptEcho = false
        corrupt.failCommands = [VIACommand.getProtocolVersion.rawValue]
        #expect(await HIDProbe.firstResponding([corrupt]) == nil)
    }
}
