import Foundation
import IOKit
import IOKit.hid

/// Watches for QMK raw-HID interfaces (usage page 0xFF60 / usage 0x61) and publishes one add/unsupported/remove event per physical keyboard.
/// Never matches the keyboard interface, so macOS never asks for Input Monitoring.
// @unchecked Sendable: `groups`/`groupOf` are only touched on `queue` (the manager's dispatch queue, where all
// IOKit callbacks run); everything else is immutable.
public final class HIDDeviceMonitor: @unchecked Sendable {
    public let events: AsyncStream<HIDDeviceEvent>
    private let continuation: AsyncStream<HIDDeviceEvent>.Continuation
    private let manager: IOHIDManager
    private let queue = DispatchQueue(label: "app.keycraft.hid.monitor")
    private let matchUsagePage: Int
    private let matchUsage: Int

    /// `usagePage`/`usage` are parameters only so the mechanics can be smoke-tested on hardware that
    /// exists; the app always uses the QMK defaults.
    public init(usagePage: Int = 0xFF60, usage: Int = 0x61) {
        (events, continuation) = AsyncStream.makeStream()
        // Independent devices: each IOHIDTransport schedules its own device on its own queue instead of
        // inheriting the manager's (IOHIDManager.h: kIOHIDManagerOptionIndependentDevices).
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOHIDManagerOptions.independentDevices.rawValue)
        matchUsagePage = usagePage
        matchUsage = usage
    }

    public func start() {
        IOHIDManagerSetDeviceMatching(manager, [kIOHIDDeviceUsagePageKey: matchUsagePage,
                                                kIOHIDDeviceUsageKey: matchUsage] as CFDictionary)
        // Retain balanced in the cancel handler (IOHIDManager.h: release only after cancel handler ran).
        let context = Unmanaged.passRetained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue().matched(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<HIDDeviceMonitor>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        nonisolated(unsafe) let releaseContext = context // opaque pointer, only used to balance the retain above
        IOHIDManagerSetCancelHandler(manager) { Unmanaged<HIDDeviceMonitor>.fromOpaque(releaseContext).release() }
        IOHIDManagerSetDispatchQueue(manager, queue)
        IOHIDManagerActivate(manager)
        // Devices already attached are reported through the matching callback once the manager is live.
        IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    public func stop() {
        IOHIDManagerCancel(manager)
        queue.async { [self] in
            for group in groups.values { for m in group.members { m.transport.close() } }
            groups.removeAll()
            groupOf.removeAll()
            continuation.finish()
        }
    }

    // MARK: Interfaces -> one physical keyboard
    // A keyboard can expose several 0xFF60/0x61 interfaces (different report sizes, only one speaking VIA).
    // Interfaces with the same vid/pid/serial/locationID are one keyboard: after a short settle time each is
    // asked `get_protocol_version` (read-only) and the first that echoes it is announced, once. If none does,
    // the keyboard is announced once as `.unsupported`. Same flow the-via/app uses (getRecognisedDevices -> canConnect).

    private struct GroupKey: Hashable {
        let vendorID: Int, productID: Int, serial: String?, locationID: Int
        init(_ info: HIDDeviceInfo) { (vendorID, productID, serial, locationID) = (info.vendorID, info.productID, info.serial, info.locationID) }
    }
    private struct Group {
        var members: [(device: ObjectIdentifier, transport: IOHIDTransport)] = []
        var tried: Set<ObjectIdentifier> = []
        var probing = false
        var announced: (id: String, supported: Bool)?
    }
    private var groups: [GroupKey: Group] = [:]
    private var groupOf: [ObjectIdentifier: GroupKey] = [:]

    private func matched(_ device: IOHIDDevice) {
        let id = ObjectIdentifier(device)
        guard groupOf[id] == nil else { return }
        let info = HIDDeviceInfo(device: device)
        let transport: IOHIDTransport
        do { transport = try IOHIDTransport(device: device) } catch {
            continuation.yield(.openFailed(info, error))
            return
        }
        let key = GroupKey(info)
        groupOf[id] = key
        groups[key, default: Group()].members.append((id, transport))
        guard groups[key]?.announced?.supported != true else { transport.close(); return } // already have a VIA interface
        if groups[key]?.probing == false {
            groups[key]?.probing = true
            queue.asyncAfter(deadline: .now() + .milliseconds(250)) { [self] in probe(key) } // let sibling interfaces show up
        }
    }

    private func probe(_ key: GroupKey) {
        guard let group = groups[key] else { return }
        let untried = group.members.filter { !group.tried.contains($0.device) }
        groups[key]?.tried.formUnion(untried.map(\.device))
        Task { [self] in
            let winner = await HIDProbe.firstResponding(untried.map(\.transport))
            queue.async { [self] in finishProbe(key, winner: winner as? IOHIDTransport) }
        }
    }

    private func finishProbe(_ key: GroupKey, winner: IOHIDTransport?) {
        guard var group = groups[key] else { return }   // unplugged while probing
        if let winner {
            if let old = group.announced { continuation.yield(.removed(id: old.id)) } // was shown as unsupported
            group.announced = (winner.info.id, true)
            group.probing = false
            for m in group.members where m.transport !== winner { m.transport.close() }
            groups[key] = group
            continuation.yield(.added(winner.info, winner))
        } else if group.members.contains(where: { !group.tried.contains($0.device) }) {
            groups[key] = group
            probe(key)                                    // more interfaces arrived while probing
        } else {
            group.probing = false
            if group.announced == nil, let first = group.members.first {
                group.announced = (first.transport.info.id, false)
                for m in group.members.dropFirst() { m.transport.close() }
                continuation.yield(.unsupported(first.transport.info, first.transport))
            }
            groups[key] = group
        }
    }

    private func removed(_ device: IOHIDDevice) {
        guard let key = groupOf[ObjectIdentifier(device)], let group = groups.removeValue(forKey: key) else { return }
        for m in group.members { groupOf[m.device] = nil; m.transport.close() } // fails pending requests with .disconnected
        if let announced = group.announced { continuation.yield(.removed(id: announced.id)) }
    }
}

enum HIDProbe {
    /// The first transport whose reply to `get_protocol_version` echoes the command, trying them in order.
    static func firstResponding(_ transports: [any HIDTransport]) async -> (any HIDTransport)? {
        var request = [UInt8](repeating: 0, count: VIAProtocol.reportSize)
        request[0] = VIACommand.getProtocolVersion.rawValue
        for transport in transports {
            if let reply = try? await transport.send(request, timeout: VIAClient.timeout), reply.first == request[0] { return transport }
        }
        return nil
    }
}
