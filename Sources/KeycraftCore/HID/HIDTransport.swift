import Foundation

public struct HIDDeviceInfo: Sendable, Hashable, Identifiable {
    public var id: String               // IORegistry entry ID for real devices (stable per attach; locationID can be reused)
    public var vendorID: Int
    public var productID: Int
    public var productName: String
    public var manufacturer: String
    public var serial: String?
    public var locationID: Int

    public init(id: String, vendorID: Int, productID: Int, productName: String,
                manufacturer: String = "", serial: String? = nil, locationID: Int = 0) {
        self.id = id
        self.vendorID = vendorID
        self.productID = productID
        self.productName = productName
        self.manufacturer = manufacturer
        self.serial = serial
        self.locationID = locationID
    }

    /// "4335:0002"
    public var vidPid: String {
        String(format: "%04X:%04X", vendorID, productID)
    }
}

public enum HIDError: Error, Equatable, Sendable {
    case timeout
    case disconnected
    case busy                       // a second request was started while one was pending
    case invalidReportSize(Int)
    case openFailed(Int32)          // IOReturn
    case sendFailed(Int32)          // IOReturn
}

extension HIDError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .timeout: "The keyboard did not answer in time."
        case .disconnected: "The keyboard was disconnected."
        case .busy: "The keyboard is busy with another request."
        case .invalidReportSize(let n): "Report must be 32 bytes (got \(n))."
        case .openFailed(let r): "Could not open the keyboard (IOReturn \(String(format: "0x%08X", UInt32(bitPattern: r))))."
        case .sendFailed(let r): "Could not send to the keyboard (IOReturn \(String(format: "0x%08X", UInt32(bitPattern: r))))."
        }
    }
}

/// VIA reports are 32 bytes. Some interfaces use 64-byte reports: requests are zero-padded up to the
/// interface's size and only the first 32 bytes of a reply are read.
enum HIDReport {
    static func padded(_ report: [UInt8], to size: Int) -> [UInt8] {
        report.count >= size ? report : report + [UInt8](repeating: 0, count: size - report.count)
    }

    static func firstReport(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        padded(Array(bytes.prefix(VIAProtocol.reportSize)), to: VIAProtocol.reportSize)
    }
}

public protocol HIDTransport: AnyObject, Sendable {
    var info: HIDDeviceInfo { get }
    /// Sends one 32-byte request (the transport pads it to the interface's report size) and returns the next
    /// input report's first 32 bytes.
    func send(_ report: [UInt8], timeout: Duration) async throws -> [UInt8]
    func close()
}

public enum HIDDeviceEvent: Sendable {
    case added(HIDDeviceInfo, any HIDTransport)
    /// A keyboard whose interfaces all stayed silent on `get_protocol_version`. The transport (first interface) stays
    /// open so the session can try again.
    case unsupported(HIDDeviceInfo, any HIDTransport)
    case removed(id: String)
    case openFailed(HIDDeviceInfo, HIDError)
}
