import Foundation
import IOKit
import IOKit.hid
import os

/// One-slot request/response bridge between a synchronous "write" + an input-report callback and Swift
/// concurrency. At most one request is pending. The continuation is taken out of the lock-guarded state
/// before it is resumed, so it is resumed exactly once whichever of {report, timeout, close, send error}
/// wins; the losers find the slot empty and do nothing (a late report after a timeout is dropped).
// ponytail: a late reply for request N-1 that lands while request N is pending cannot be told apart here;
// VIAClient's echo check catches it unless the two requests are identical. Add sequence tags if that bites.
final class ReportBridge: Sendable {
    private struct State {
        var generation = 0
        var pending: CheckedContinuation<[UInt8], any Error>?
        var closed = false
    }
    private enum Slot { case registered(Int), closed, busy }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let timerQueue = DispatchQueue(label: "app.keycraft.hid.timeout")

    /// Registers the continuation FIRST, then runs `perform` (the actual write), so a reply that arrives
    /// before `perform` returns still finds a pending slot.
    func exchange(timeout: Duration, perform: () throws -> Void) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], any Error>) in
            let slot = state.withLock { s -> Slot in
                if s.closed { return .closed }
                if s.pending != nil { return .busy }
                s.generation += 1
                s.pending = continuation
                return .registered(s.generation)
            }
            switch slot {
            case .closed: continuation.resume(throwing: HIDError.disconnected)
            case .busy: continuation.resume(throwing: HIDError.busy)
            case .registered(let generation):
                let c = timeout.components
                let nanos = c.seconds * 1_000_000_000 + c.attoseconds / 1_000_000_000
                timerQueue.asyncAfter(deadline: .now() + .nanoseconds(Int(nanos))) { [self] in
                    resolve(generation: generation, .failure(HIDError.timeout))
                }
                do { try perform() } catch { resolve(generation: generation, .failure(error)) }
            }
        }
    }

    /// Input-report callback side. Dropped if nothing is pending.
    func deliver(_ report: [UInt8]) { resolve(generation: nil, .success(report)) }

    /// Device removed / transport closed: fail the pending request and refuse new ones.
    /// Returns true only for the call that actually closed it, so callers can cancel the device exactly once.
    @discardableResult
    func close() -> Bool {
        let (first, pending) = state.withLock { s -> (Bool, CheckedContinuation<[UInt8], any Error>?) in
            defer { s.closed = true; s.pending = nil }
            return (!s.closed, s.pending)
        }
        pending?.resume(throwing: HIDError.disconnected)
        return first
    }

    private func resolve(generation: Int?, _ result: Result<[UInt8], any Error>) {
        let pending = state.withLock { s -> CheckedContinuation<[UInt8], any Error>? in
            guard let p = s.pending, generation == nil || generation == s.generation else { return nil }
            s.pending = nil
            return p
        }
        pending?.resume(with: result)
    }
}

extension HIDDeviceInfo {
    init(device: IOHIDDevice) {
        func int(_ key: String) -> Int { (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0 }
        func string(_ key: String) -> String? { IOHIDDeviceGetProperty(device, key as CFString) as? String }
        var entryID: UInt64 = 0
        IORegistryEntryGetRegistryEntryID(IOHIDDeviceGetService(device), &entryID)
        self.init(id: String(entryID),
                  vendorID: int(kIOHIDVendorIDKey),
                  productID: int(kIOHIDProductIDKey),
                  productName: string(kIOHIDProductKey) ?? "Keyboard",
                  manufacturer: string(kIOHIDManufacturerKey) ?? "",
                  serial: string(kIOHIDSerialNumberKey),
                  locationID: int(kIOHIDLocationIDKey))
    }
}

/// A real QMK raw-HID interface (usage page 0xFF60). Created and owned by `HIDDeviceMonitor`.
// @unchecked Sendable: every stored property is immutable. The IOHIDDevice ref is thread-safe per IOKit;
// the only mutable state is inside `bridge` (OSAllocatedUnfairLock); `inputBuffer` is written only by the
// IOKit input callback on `queue` and freed in deinit, which only runs after the cancel handler released
// the context retain (i.e. after IOKit guarantees no more callbacks).
public final class IOHIDTransport: HIDTransport, @unchecked Sendable {
    public let info: HIDDeviceInfo
    private let device: IOHIDDevice
    private let queue = DispatchQueue(label: "app.keycraft.hid.device")
    private let bridge = ReportBridge()
    private let inputBuffer: UnsafeMutablePointer<UInt8>
    private let inputSize: Int
    private let outputSize: Int

    init(device: IOHIDDevice) throws(HIDError) {
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        guard result == kIOReturnSuccess else { throw .openFailed(result) }
        self.device = device
        self.info = HIDDeviceInfo(device: device)
        func size(_ key: String) -> Int { max((IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue ?? 0, VIAProtocol.reportSize) }
        inputSize = size(kIOHIDMaxInputReportSizeKey)
        outputSize = size(kIOHIDMaxOutputReportSizeKey)
        inputBuffer = .allocate(capacity: inputSize)
        inputBuffer.initialize(repeating: 0, count: inputSize)

        // IOHIDDevice.h: register callbacks BEFORE IOHIDDeviceActivate; every activated device must be
        // cancelled, and resources may only be released from the cancel handler. The context retain below
        // is balanced there (IOHIDDeviceSetCancelHandler docs), so callbacks never see a freed `self`.
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDDeviceRegisterInputReportCallback(device, inputBuffer, inputSize, { context, _, _, _, _, report, length in
            guard let context else { return }
            let transport = Unmanaged<IOHIDTransport>.fromOpaque(context).takeUnretainedValue()
            transport.bridge.deliver(HIDReport.firstReport(UnsafeBufferPointer(start: report, count: Int(length))))
        }, context)
        IOHIDDeviceRegisterRemovalCallback(device, { context, _, _ in
            guard let context else { return }
            Unmanaged<IOHIDTransport>.fromOpaque(context).takeUnretainedValue().close()
        }, context)
        nonisolated(unsafe) let releaseContext = context // opaque pointer, only used to balance the retain above
        IOHIDDeviceSetCancelHandler(device) { Unmanaged<IOHIDTransport>.fromOpaque(releaseContext).release() }
        IOHIDDeviceSetDispatchQueue(device, queue)
        IOHIDDeviceActivate(device)
    }

    deinit { inputBuffer.deallocate() }

    public func send(_ report: [UInt8], timeout: Duration) async throws -> [UInt8] {
        guard report.count == VIAProtocol.reportSize else { throw HIDError.invalidReportSize(report.count) }
        // Report ID 0, payload only: IOKit takes no leading report-ID byte (WebHID's 33-byte form is not used here).
        let padded = HIDReport.padded(report, to: outputSize)
        return try await bridge.exchange(timeout: timeout) {
            let result = padded.withUnsafeBufferPointer {
                IOHIDDeviceSetReport(device, kIOHIDReportTypeOutput, 0, $0.baseAddress!, padded.count)
            }
            if result != kIOReturnSuccess { throw HIDError.sendFailed(result) }
        }
    }

    /// Idempotent: fails any pending request, then closes and cancels the device exactly once.
    public func close() {
        guard bridge.close() else { return }
        IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDDeviceCancel(device)
    }
}
