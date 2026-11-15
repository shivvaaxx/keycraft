import Foundation
import os

/// An in-memory keyboard that speaks VIA protocol 0x000C with 4 layers. `init()` is laid out like the GH60 Satan
/// definition (5 x 14 matrix); `init(definition:)` emulates any library entry. Echoes requests like real
/// firmware (via.c:487-489).
public final class MockVIADevice: HIDTransport {
    public static let macroBufferSize = 256
    public let rows: Int
    public let cols: Int
    public let layers = 4

    private struct State {
        var keymap: [UInt8]
        var macros = [UInt8](repeating: 0, count: MockVIADevice.macroBufferSize)
        var failCommands: Set<UInt8> = []
        var corruptEcho = false
        var sent: [[UInt8]] = []
    }
    private let state: OSAllocatedUnfairLock<State>

    public let info: HIDDeviceInfo

    /// Commands listed here time out (`HIDError.timeout`) instead of answering.
    public var failCommands: Set<UInt8> {
        get { state.withLock { $0.failCommands } }
        set { state.withLock { $0.failCommands = newValue } }
    }
    /// Flips the first argument byte of every reply so it no longer echoes the request.
    public var corruptEcho: Bool {
        get { state.withLock { $0.corruptEcho } }
        set { state.withLock { $0.corruptEcho = newValue } }
    }
    /// Every report received, in order (for tests).
    public var sentReports: [[UInt8]] { state.withLock { $0.sent } }
    /// Current keymap in firmware byte order (layer-major, row-major, big-endian u16).
    public var keymapBytes: [UInt8] { state.withLock { $0.keymap } }
    /// The raw macro buffer.
    public var macroBytes: [UInt8] { state.withLock { $0.macros } }

    public convenience init() {
        self.init(rows: 5, cols: 14, layerZero: Self.layerZero.flatMap { $0 },
                  info: HIDDeviceInfo(id: "demo", vendorID: 0x4335, productID: 0x0002,
                                      productName: "Demo Keyboard (GH60 Satan)", manufacturer: "Keycraft"))
    }

    /// Layer 0 gets letters then digits, in the order the definition lists its visible keys; other matrix
    /// positions are None. (Definitions carry no key legends to copy, so there is nothing "default" to read.)
    public convenience init(definition: VIADefinition) {
        var layerZero = [UInt16](repeating: Keycode.none, count: definition.rows * definition.cols)
        for (i, key) in definition.keys.enumerated() { layerZero[key.row * definition.cols + key.col] = UInt16(0x04 + i % 36) }
        self.init(rows: definition.rows, cols: definition.cols, layerZero: layerZero,
                  info: HIDDeviceInfo(id: "demo-" + String(format: "%04x-%04x", definition.vendorID, definition.productID),
                                      vendorID: definition.vendorID, productID: definition.productID,
                                      productName: definition.name, manufacturer: "Keycraft"))
    }

    private init(rows: Int, cols: Int, layerZero: [UInt16], info: HIDDeviceInfo) {
        (self.rows, self.cols, self.info) = (rows, cols, info)
        var bytes: [UInt8] = []
        for layer in 0..<layers {
            for code in layer == 0 ? layerZero : [UInt16](repeating: Keycode.transparent, count: rows * cols) {
                bytes += [UInt8(code >> 8), UInt8(code & 0xFF)]
            }
        }
        state = OSAllocatedUnfairLock(initialState: State(keymap: bytes))
    }

    public func close() {}

    public func send(_ report: [UInt8], timeout: Duration) async throws -> [UInt8] {
        guard report.count == VIAProtocol.reportSize else { throw HIDError.invalidReportSize(report.count) }
        return try state.withLock { s in
            s.sent.append(report)
            if s.failCommands.contains(report[0]) { throw HIDError.timeout }
            var r = report
            if !handle(&r, &s) { r[0] = VIACommand.unhandled.rawValue }
            if s.corruptEcho { r[1] ^= 0xFF }
            return r
        }
    }

    /// Mutates `r` in place like via.c's raw_hid_receive. Returns false for unknown or out-of-range requests.
    private func handle(_ r: inout [UInt8], _ s: inout State) -> Bool {
        let perLayer = rows * cols * 2
        switch VIACommand(rawValue: r[0]) {
        case .getProtocolVersion:
            r[1] = 0x00; r[2] = 0x0C
        case .getKeycode:
            let (layer, row, col) = (Int(r[1]), Int(r[2]), Int(r[3]))
            guard layer < layers, row < rows, col < cols else { return false }
            let o = layer * perLayer + (row * cols + col) * 2
            r[4] = s.keymap[o]; r[5] = s.keymap[o + 1]
        case .setKeycode:
            let (layer, row, col) = (Int(r[1]), Int(r[2]), Int(r[3]))
            guard layer < layers, row < rows, col < cols else { return false }
            let o = layer * perLayer + (row * cols + col) * 2
            s.keymap[o] = r[4]; s.keymap[o + 1] = r[5]
        case .macroGetCount:
            r[1] = 4
        case .macroGetBufferSize:
            r[1] = UInt8(Self.macroBufferSize >> 8); r[2] = UInt8(Self.macroBufferSize & 0xFF)
        case .macroGetBuffer:
            let (offset, size) = (Int(r[1]) << 8 | Int(r[2]), Int(r[3]))
            guard size <= VIAProtocol.maxChunk, offset + size <= s.macros.count else { return false }
            r.replaceSubrange(4..<4 + size, with: s.macros[offset..<offset + size])
        case .macroSetBuffer:
            let (offset, size) = (Int(r[1]) << 8 | Int(r[2]), Int(r[3]))
            guard size <= VIAProtocol.maxChunk, offset + size <= s.macros.count else { return false }
            s.macros.replaceSubrange(offset..<offset + size, with: r[4..<4 + size])
        case .getLayerCount:
            r[1] = UInt8(layers)
        case .keymapGetBuffer:
            let (offset, size) = (Int(r[1]) << 8 | Int(r[2]), Int(r[3]))
            guard size <= VIAProtocol.maxChunk, offset + size <= s.keymap.count else { return false }
            r.replaceSubrange(4..<4 + size, with: s.keymap[offset..<offset + size])
        case .keymapSetBuffer:
            let (offset, size) = (Int(r[1]) << 8 | Int(r[2]), Int(r[3]))
            guard size <= VIAProtocol.maxChunk, offset + size <= s.keymap.count else { return false }
            s.keymap.replaceSubrange(offset..<offset + size, with: r[4..<4 + size])
        default:
            return false
        }
        return true
    }

    // Layer 0 as [row][col] matrix positions of the GH60 Satan definition (ANSI options). Positions that only
    // exist in non-default layout options are filled sensibly too.
    private static let layerZero: [[UInt16]] = [
        // row 0: Esc 1 2 3 4 5 6 7 8 9 0 - =  Backspace
        [0x29, 0x1E, 0x1F, 0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x2D, 0x2E, 0x2A],
        // row 1: Tab Q W E R T Y U I O P [ ]  \
        [0x2B, 0x14, 0x1A, 0x08, 0x15, 0x17, 0x1C, 0x18, 0x0C, 0x12, 0x13, 0x2F, 0x30, 0x31],
        // row 2: Caps A S D F G H J K L ; '  (ISO #)  Enter
        [0x39, 0x04, 0x16, 0x07, 0x09, 0x0A, 0x0B, 0x0D, 0x0E, 0x0F, 0x33, 0x34, 0x32, 0x28],
        // row 3: LShift (ISO \) Z X C V B N M , . /  (split RShift)  RShift
        [0xE1, 0x64, 0x1D, 0x1B, 0x06, 0x19, 0x05, 0x11, 0x10, 0x36, 0x37, 0x38, 0x00, 0xE5],
        // row 4: Ctrl Cmd Opt . . Space . . . . . Opt Cmd Menu Ctrl; (4,9) = Backspace for the split-backspace option
        [0xE0, 0xE3, 0xE2, 0x00, 0x00, 0x2C, 0x00, 0x00, 0x00, 0x2A, 0xE6, 0xE7, 0x65, 0xE4],
    ]
}
