import Foundation

/// Command IDs: via.h:54-76 (enum via_command_id); keyboard-api.ts:21-51 agrees.
public enum VIACommand: UInt8, Sendable {
    case getProtocolVersion = 0x01      // via.h:55  response[1..2] = version BE (via.c:301-305)
    case getKeyboardValue = 0x02
    case setKeyboardValue = 0x03
    case getKeycode = 0x04              // via.h:58  response[4..5] = keycode BE (via.c:398-402)
    case setKeycode = 0x05              // via.h:59  args [layer,row,col,hi,lo] (via.c:404-406)
    case keymapReset = 0x06             // NEVER sent in this slice
    case customSet = 0x07
    case customGet = 0x08
    case customSave = 0x09
    case eepromReset = 0x0A             // NEVER sent in this slice
    case bootloaderJump = 0x0B          // NEVER sent in this slice
    case macroGetCount = 0x0C           // response[1] (via.c:425-428)
    case macroGetBufferSize = 0x0D      // response[1..2] BE (via.c:429-434)
    case macroGetBuffer = 0x0E          // args [offHi,offLo,size], data at response[4...] (via.c:435-440)
    case macroSetBuffer = 0x0F
    case macroReset = 0x10              // NEVER sent in this slice
    case getLayerCount = 0x11           // response[1] (via.c:451-454)
    case keymapGetBuffer = 0x12         // args [offHi,offLo,size<=28], data at response[4...] (via.c:455-460)
    case keymapSetBuffer = 0x13         // args [offHi,offLo,size<=28,data...] (via.c:461-466)
    case unhandled = 0xFF               // via.h:76; firmware sets byte0 to this (via.c:479-483)

    /// Destructive commands this slice must never send.
    static let forbidden: Set<VIACommand> = [.keymapReset, .eepromReset, .bootloaderJump, .macroReset]
}

public enum VIAError: Error, Equatable, Sendable {
    case badResponse(command: UInt8)
    case unhandled(command: UInt8)
    case verifyFailed(expected: UInt16, actual: UInt16)
    case forbiddenCommand(UInt8)
    case unsupportedProtocol(Int)
    case invalidKeymapSize(expected: Int, actual: Int)
    case macrosTooLong(bytes: Int, limit: Int)
    case macroVerifyFailed
}

extension VIAError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .badResponse(let c): "The keyboard sent an unexpected reply to command 0x\(String(c, radix: 16, uppercase: true))."
        case .unhandled(let c): "The keyboard's firmware does not support command 0x\(String(c, radix: 16, uppercase: true))."
        case .verifyFailed(let e, let a): "Verification failed: wrote \(String(format: "0x%04X", e)) but read back \(String(format: "0x%04X", a))."
        case .forbiddenCommand(let c): "Command 0x\(String(c, radix: 16, uppercase: true)) is blocked in this version."
        case .unsupportedProtocol(let v): "VIA protocol version \(v) is not supported."
        case .invalidKeymapSize(let e, let a): "Backup keymap is \(a) bytes but this keyboard needs \(e)."
        case .macrosTooLong(let b, let l): "The macros need \(b) bytes but this keyboard has room for \(l). Shorten or remove some."
        case .macroVerifyFailed: "The macros read back from the keyboard didn't match what was written. Try saving again."
        }
    }
}

public enum VIAProtocol {
    public static let reportSize = 32
    /// Max payload per buffer command (via.c:457 "size <= 28"; keyboard-api.ts:272).
    public static let maxChunk = 28
    public static let alpha = 7         // keyboard-api.ts:145 PROTOCOL_ALPHA (per-key reads only)
    public static let beta = 8          // keyboard-api.ts:146 PROTOCOL_BETA (get_layer_count + buffer commands)
    /// QMK "v2" keycodes (spec: VIA protocol >= 12).
    public static let keycodesV2 = 12
    public static let assumedLayerCount = 4  // keyboard-api.ts:257
}
