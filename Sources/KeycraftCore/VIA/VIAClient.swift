import Foundation

/// Owns one HID transport and runs VIA requests strictly one at a time.
public actor VIAClient {
    public static let timeout = Duration.milliseconds(500)

    private let transport: any HIDTransport
    private var cachedVersion: Int?
    // An actor re-enters at every `await`, so "one request in flight" needs an explicit FIFO gate.
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(transport: any HIDTransport) { self.transport = transport }

    public nonisolated var info: HIDDeviceInfo { transport.info }

    // MARK: Request core

    private func acquire() async {
        if busy { await withCheckedContinuation { waiters.append($0) } } else { busy = true }
    }
    private func release() {
        if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() } // hand-off keeps busy == true
    }

    /// Frames `command + args` zero-padded to 32 bytes and checks the reply echoes them
    /// (keyboard-api.ts:_hidCommand compares commandBytes.slice(1) with the response prefix).
    /// Reads retry once on timeout; writes never retry blindly.
    func request(_ command: VIACommand, _ args: [UInt8] = [], isRead: Bool) async throws -> [UInt8] {
        guard !VIACommand.forbidden.contains(command) else { throw VIAError.forbiddenCommand(command.rawValue) }
        precondition(args.count < VIAProtocol.reportSize)
        await acquire()
        defer { release() }

        let sent = [command.rawValue] + args
        var report = [UInt8](repeating: 0, count: VIAProtocol.reportSize)
        report.replaceSubrange(0..<sent.count, with: sent)

        var attempt = 0
        while true {
            do {
                let response = try await transport.send(report, timeout: Self.timeout)
                guard response.count == VIAProtocol.reportSize else { throw VIAError.badResponse(command: command.rawValue) }
                if response[0] == VIACommand.unhandled.rawValue { throw VIAError.unhandled(command: command.rawValue) } // before echo check
                guard Array(response[0..<sent.count]) == sent else { throw VIAError.badResponse(command: command.rawValue) }
                return response
            } catch let error as HIDError where error == .timeout && isRead && attempt == 0 {
                attempt += 1
            }
        }
    }

    // MARK: Reads

    /// keyboard-api.ts:231-238, via.c:301-305.
    public func protocolVersion() async throws -> Int {
        if let cachedVersion { return cachedVersion }
        let r = try await request(.getProtocolVersion, isRead: true)
        let version = Int(r[1]) << 8 | Int(r[2])
        cachedVersion = version
        return version
    }

    /// keyboard-api.ts:248-258: asks the keyboard only when protocol >= PROTOCOL_BETA (8), else assumes 4.
    public func layerCount() async throws -> Int {
        guard try await protocolVersion() >= VIAProtocol.beta else { return VIAProtocol.assumedLayerCount }
        return Int(try await request(.getLayerCount, isRead: true)[1])
    }

    /// keyboard-api.ts:240-246: keycode at response[4]<<8 | response[5].
    public func keycode(layer: Int, row: Int, col: Int) async throws -> UInt16 {
        let r = try await request(.getKeycode, [UInt8(layer), UInt8(row), UInt8(col)], isRead: true)
        return UInt16(r[4]) << 8 | UInt16(r[5])
    }

    /// Whole keymap as the firmware stores it: layer-major, row-major, big-endian u16 (offset of layer L
    /// is L*rows*cols*2). Protocol >= 8 uses 28-byte buffer reads; protocol 7 falls back to per-key reads
    /// (keyboard-api.ts:260-269).
    public func readKeymapBytes(layers: Int, rows: Int, cols: Int) async throws -> [UInt8] {
        let version = try await protocolVersion()
        var bytes: [UInt8] = []
        let total = layers * rows * cols * 2
        // Buffer reads take a 16-bit offset; a larger keymap can't be addressed (and UInt8(offset >> 8) would trap).
        guard total > 0, total <= 0x10000 else { throw VIAError.invalidKeymapSize(expected: total, actual: 0x10000) }
        bytes.reserveCapacity(total)
        if version >= VIAProtocol.beta {
            while bytes.count < total {
                let size = min(VIAProtocol.maxChunk, total - bytes.count)
                let offset = bytes.count
                let r = try await request(.keymapGetBuffer, [UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(size)], isRead: true)
                bytes += r[4..<4 + size]
            }
        } else if version == VIAProtocol.alpha {
            for layer in 0..<layers { for row in 0..<rows { for col in 0..<cols {
                let code = try await keycode(layer: layer, row: row, col: col)
                bytes += [UInt8(code >> 8), UInt8(code & 0xFF)]
            } } }
        } else {
            throw VIAError.unsupportedProtocol(version)
        }
        return bytes
    }

    /// `[layer][row * cols + col]`
    public func readKeymap(layers: Int, rows: Int, cols: Int) async throws -> [[UInt16]] {
        let bytes = try await readKeymapBytes(layers: layers, rows: rows, cols: cols)
        let perLayer = rows * cols
        return (0..<layers).map { layer in
            (0..<perLayer).map { i in
                let o = (layer * perLayer + i) * 2
                return UInt16(bytes[o]) << 8 | UInt16(bytes[o + 1])
            }
        }
    }

    // MARK: Writes

    /// Writes one key then reads it back; throws `.verifyFailed` if it differs. No blind retry on the write.
    public func setKeycode(layer: Int, row: Int, col: Int, keycode code: UInt16) async throws {
        _ = try await request(.setKeycode, [UInt8(layer), UInt8(row), UInt8(col), UInt8(code >> 8), UInt8(code & 0xFF)], isRead: false)
        let actual = try await keycode(layer: layer, row: row, col: col)
        guard actual == code else { throw VIAError.verifyFailed(expected: code, actual: actual) }
    }

    /// Restore: writes a whole keymap (same byte layout as `readKeymapBytes`) with 28-byte set_buffer
    /// commands, then re-reads everything and verifies.
    public func writeKeymapBytes(_ data: [UInt8], layers: Int, rows: Int, cols: Int) async throws {
        let version = try await protocolVersion()
        guard version >= VIAProtocol.beta else { throw VIAError.unsupportedProtocol(version) }
        let expected = layers * rows * cols * 2
        guard data.count == expected else { throw VIAError.invalidKeymapSize(expected: expected, actual: data.count) }
        var offset = 0
        while offset < data.count {
            let chunk = Array(data[offset..<min(offset + VIAProtocol.maxChunk, data.count)])
            _ = try await request(.keymapSetBuffer, [UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(chunk.count)] + chunk, isRead: false)
            offset += chunk.count
        }
        let back = try await readKeymapBytes(layers: layers, rows: rows, cols: cols)
        if let i = zip(back, data).enumerated().first(where: { $0.element.0 != $0.element.1 })?.offset {
            let w = i & ~1
            throw VIAError.verifyFailed(expected: UInt16(data[w]) << 8 | UInt16(data[w + 1]),
                                        actual: UInt16(back[w]) << 8 | UInt16(back[w + 1]))
        }
    }

    // MARK: Macros  keyboard-api.ts:567-620

    public func macroCount() async throws -> Int {
        Int(try await request(.macroGetCount, isRead: true)[1])
    }

    public func macroBufferSize() async throws -> Int {
        let r = try await request(.macroGetBufferSize, isRead: true)
        return Int(r[1]) << 8 | Int(r[2])
    }

    public func readMacroBuffer(size total: Int) async throws -> [UInt8] {
        var bytes: [UInt8] = []
        while bytes.count < total {
            let size = min(VIAProtocol.maxChunk, total - bytes.count)
            let offset = bytes.count
            let r = try await request(.macroGetBuffer, [UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(size)], isRead: true)
            bytes += r[4..<4 + size]
        }
        return bytes
    }

    /// The macros on the keyboard. Throws `unsupportedProtocol` before VIA protocol 11, whose encoding differs.
    public func readMacros() async throws -> (macros: [[MacroStep]], bufferSize: Int) {
        let version = try await protocolVersion()
        guard version >= Macros.minimumProtocol else { throw VIAError.unsupportedProtocol(version) }
        let count = try await macroCount()
        let size = try await macroBufferSize()
        return (Macros.decode(try await readMacroBuffer(size: size), count: count), size)
    }

    /// Replaces every macro. Like VIA, the buffer's last byte is set non-zero while writing so the firmware
    /// ignores a half-written buffer (dynamic_keymap.c:149), then cleared; everything is read back and verified.
    public func writeMacros(_ macros: [[MacroStep]]) async throws {
        let version = try await protocolVersion()
        guard version >= Macros.minimumProtocol else { throw VIAError.unsupportedProtocol(version) }
        let size = try await macroBufferSize()
        var data = Macros.encode(macros)
        guard data.count < size else { throw VIAError.macrosTooLong(bytes: data.count, limit: size - 1) }
        data += [UInt8](repeating: 0, count: size - data.count)
        let last = size - 1
        _ = try await request(.macroSetBuffer, [UInt8(last >> 8), UInt8(last & 0xFF), 1, 0xFF], isRead: false)
        var offset = 0
        while offset < last {
            let chunk = Array(data[offset..<min(offset + VIAProtocol.maxChunk, last)])
            _ = try await request(.macroSetBuffer, [UInt8(offset >> 8), UInt8(offset & 0xFF), UInt8(chunk.count)] + chunk, isRead: false)
            offset += chunk.count
        }
        _ = try await request(.macroSetBuffer, [UInt8(last >> 8), UInt8(last & 0xFF), 1, 0x00], isRead: false)
        let back = try await readMacroBuffer(size: size)
        guard back == data else { throw VIAError.macroVerifyFailed }
    }

    // MARK: Backup items (this driver's declaration)

    public nonisolated func backupItems(layers: Int, rows: Int, cols: Int) -> [BackupItem] {
        [
            BackupItem(id: "keymap", name: "Keymap (all layers)", importance: .important) {
                Data(try await self.readKeymapBytes(layers: layers, rows: rows, cols: cols))
            },
            // Layout: [count, sizeHi, sizeLo] + raw macro buffer.
            BackupItem(id: "macros", name: "Macros", importance: .important) {
                let count = try await self.macroCount()
                let size = try await self.macroBufferSize()
                let buffer = try await self.readMacroBuffer(size: size)
                return Data([UInt8(count), UInt8(size >> 8), UInt8(size & 0xFF)] + buffer)
            },
            BackupItem(id: "firmware", name: "Firmware image", importance: .important,
                       notSupportedReason: "VIA keyboards can't read their firmware back over USB") { nil },
            BackupItem(id: "lighting", name: "Lighting", importance: .optional,
                       notSupportedReason: "Not implemented yet") { nil },
        ]
    }
}
