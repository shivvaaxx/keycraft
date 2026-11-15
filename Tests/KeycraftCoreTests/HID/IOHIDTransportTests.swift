import Dispatch
import Foundation
import Testing
@testable import KeycraftCore

/// The IOKit callback <-> async bridge, exercised without hardware.
@Suite struct IOHIDTransportTests {
    let bridge = ReportBridge()
    let report = [UInt8](repeating: 7, count: 32)

    @Test func reportArrivingBeforeWriteReturnsStillResolves() async throws {
        // the slot is registered before `perform` runs, so a reply that lands inside it is not lost
        let result = try await bridge.exchange(timeout: .seconds(1)) { bridge.deliver(report) }
        #expect(result == report)
    }

    @Test func reportFromAnotherQueueResolves() async throws {
        let result = try await bridge.exchange(timeout: .seconds(1)) {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) { [bridge, report] in bridge.deliver(report) }
        }
        #expect(result == report)
    }

    @Test func timeoutResumesOnceAndLateReportIsDropped() async throws {
        await #expect(throws: HIDError.timeout) { _ = try await bridge.exchange(timeout: .milliseconds(30)) {} }
        bridge.deliver(report)                    // late: nothing pending, must be ignored
        let next = try await bridge.exchange(timeout: .seconds(1)) { bridge.deliver([UInt8](repeating: 9, count: 32)) }
        #expect(next == [UInt8](repeating: 9, count: 32))   // not the stale `report`
    }

    @Test func staleTimerFromAnEarlierRequestDoesNotKillTheNextOne() async throws {
        // request 1 completes quickly, leaving its 80 ms timer armed; request 2 must outlive that timer
        _ = try await bridge.exchange(timeout: .milliseconds(80)) { bridge.deliver(report) }
        let second = try await bridge.exchange(timeout: .seconds(1)) {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(200)) { [bridge, report] in bridge.deliver(report) }
        }
        #expect(second == report)
    }

    @Test func doubleDeliveryAndTimerAfterSuccessDoNotDoubleResume() async throws {
        _ = try await bridge.exchange(timeout: .milliseconds(30)) { bridge.deliver(report); bridge.deliver(report) }
        try await Task.sleep(for: .milliseconds(80)) // let the timer fire after the fact; a double resume would trap
    }

    @Test func closeFailsPendingRequestAndRefusesNewOnes() async throws {
        let pending = Task { [bridge] in try await bridge.exchange(timeout: .seconds(5)) {} }
        try await Task.sleep(for: .milliseconds(30))
        bridge.close()
        await #expect(throws: HIDError.disconnected) { _ = try await pending.value }
        await #expect(throws: HIDError.disconnected) { _ = try await bridge.exchange(timeout: .seconds(1)) {} }
    }

    @Test func secondConcurrentRequestIsBusy() async throws {
        let first = Task { [bridge] in try await bridge.exchange(timeout: .seconds(5)) {} }
        try await Task.sleep(for: .milliseconds(30))
        await #expect(throws: HIDError.busy) { _ = try await bridge.exchange(timeout: .seconds(1)) {} }
        bridge.deliver(report)
        #expect(try await first.value == report)
    }

    @Test func failedWritePropagatesOnce() async throws {
        await #expect(throws: HIDError.sendFailed(-1)) {
            _ = try await bridge.exchange(timeout: .milliseconds(30)) { throw HIDError.sendFailed(-1) }
        }
        try await Task.sleep(for: .milliseconds(80)) // its timer fires later and must find the slot empty
    }

    @Test func closeReportsTheFirstCallOnly() {
        #expect(bridge.close() == true)     // IOHIDTransport.close() cancels the device only when this is true
        #expect(bridge.close() == false)
        #expect(bridge.close() == false)
    }

    @Test func requestIsPaddedAndReplyTrimmedTo32Bytes() {
        let request = [UInt8](repeating: 1, count: 32)
        #expect(HIDReport.padded(request, to: 64) == request + [UInt8](repeating: 0, count: 32))
        #expect(HIDReport.padded(request, to: 32) == request)
        let reply = [UInt8](0..<64)
        #expect(reply.withUnsafeBufferPointer { HIDReport.firstReport($0) } == Array(0..<32))
        let short: [UInt8] = [9, 8]
        #expect(short.withUnsafeBufferPointer { HIDReport.firstReport($0) } == [9, 8] + [UInt8](repeating: 0, count: 30))
    }
}
