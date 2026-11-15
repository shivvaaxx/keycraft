import Foundation

/// QMK's names for keycodes, both ways. Single-key names come from QMK's keycodes.h (see the generated file);
/// composite keys (MT, LT, MO, LCTL(...), ...) follow quantum_keycodes.h and modifiers.h. QMK v2 keycodes only.
public enum QMKNames {
    private static let parsed: (byCode: [UInt16: String], byName: [String: UInt16]) = {
        var all: [UInt16: [(name: String, isAlias: Bool)]] = [:]
        var byName: [String: UInt16] = ["KC_HYPR": 0x0F00, "KC_MEH": 0x0700]
        for line in source.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count >= 2, let code = UInt16(parts[0], radix: 16) else { continue }
            let name = String(parts[1])
            byName[name] = code
            all[code, default: []].append((name, parts.count > 2))
        }
        // Export the name people write: the shortest (KC_ENT over KC_ENTER), canonical on a tie.
        var byCode = all.mapValues { names in
            names.min { ($0.name.count, $0.isAlias ? 1 : 0) < ($1.name.count, $1.isAlias ? 1 : 0) }!.name
        }
        byCode[0x0000] = "XXXXXXX"
        byCode[0x0001] = "_______"
        return (byCode, byName)
    }()

    /// The single name QMK uses for this exact code, if there is one.
    public static func name(_ code: UInt16) -> String? { parsed.byCode[code] }
    /// Any single-key name QMK accepts, aliases included.
    public static func code(_ name: String) -> UInt16? { parsed.byName[name] }

    // MARK: Modifier masks (modifiers.h: MOD_LCTL 0x01 ... 0x10 = right hand)

    static let modifierMasks: [String: UInt8] = [
        "MOD_LCTL": 0x01, "MOD_LSFT": 0x02, "MOD_LALT": 0x04, "MOD_LGUI": 0x08,
        "MOD_RCTL": 0x11, "MOD_RSFT": 0x12, "MOD_RALT": 0x14, "MOD_RGUI": 0x18,
        "MOD_HYPR": 0x0F, "MOD_MEH": 0x07,
    ]

    static func modifierExpression(_ m: UInt8) -> String {
        let right = m & 0x10 != 0
        if !right, m & 0x0F == 0x0F { return "MOD_HYPR" }
        if !right, m & 0x0F == 0x07 { return "MOD_MEH" }
        let side = right ? "R" : "L"
        return [(0x01, "CTL"), (0x02, "SFT"), (0x04, "ALT"), (0x08, "GUI")]
            .filter { m & UInt8($0.0) != 0 }.map { "MOD_\(side)\($0.1)" }.joined(separator: " | ")
    }

    /// Wrapper functions that add modifiers to a key (LCTL(KC_C) = 0x0106). Value is the mod mask.
    static let modifierWrappers: [String: UInt8] = [
        "LCTL": 0x01, "C": 0x01, "LSFT": 0x02, "S": 0x02, "LALT": 0x04, "LOPT": 0x04, "A": 0x04,
        "LGUI": 0x08, "LCMD": 0x08, "LWIN": 0x08, "G": 0x08,
        "RCTL": 0x11, "RSFT": 0x12, "RALT": 0x14, "ROPT": 0x14, "ALGR": 0x14, "RGUI": 0x18, "RCMD": 0x18, "RWIN": 0x18,
        "HYPR": 0x0F, "MEH": 0x07,
    ]

    /// Mod-tap shorthands (LCTL_T(kc) = MT(MOD_LCTL, kc)).
    static let modTapShorthands: [String: UInt8] = [
        "LCTL_T": 0x01, "CTL_T": 0x01, "LSFT_T": 0x02, "SFT_T": 0x02, "LALT_T": 0x04, "LOPT_T": 0x04, "ALT_T": 0x04, "OPT_T": 0x04,
        "LGUI_T": 0x08, "LCMD_T": 0x08, "LWIN_T": 0x08, "GUI_T": 0x08, "CMD_T": 0x08, "WIN_T": 0x08,
        "RCTL_T": 0x11, "RSFT_T": 0x12, "RALT_T": 0x14, "ROPT_T": 0x14, "ALGR_T": 0x14, "RGUI_T": 0x18, "RCMD_T": 0x18, "RWIN_T": 0x18,
        "HYPR_T": 0x0F, "ALL_T": 0x0F, "MEH_T": 0x07, "C_S_T": 0x03, "LCS_T": 0x03,
    ]

    /// Single-argument layer functions and their range bases (quantum_keycodes.h).
    static let layerFunctions: [String: UInt16] = ["TO": 0x5200, "MO": 0x5220, "DF": 0x5240, "TG": 0x5260, "OSL": 0x5280, "TT": 0x52C0]

    // MARK: Export

    /// The QMK expression for a keycode, or nil when it can't be written safely (older VIA keycodes that
    /// mean something else to current QMK).
    public static func expression(_ code: UInt16, protocolVersion: Int = VIAProtocol.keycodesV2) -> String? {
        func basic(_ c: UInt16) -> String { name(c & 0xFF) ?? String(format: "0x%02X", c & 0xFF) }
        // Basic keys and modifier combinations are numbered the same in old and new QMK.
        switch code {
        case 0x0000...0x00FF: return name(code) ?? String(format: "0x%04X", code)
        case 0x0100...0x1FFF:
            let mods = UInt8(code >> 8)
            if code == 0x0F00 { return "KC_HYPR" }
            if code == 0x0700 { return "KC_MEH" }
            if mods & 0x0F == 0x0F, mods & 0x10 == 0 { return "HYPR(\(basic(code)))" }
            if mods & 0x0F == 0x07, mods & 0x10 == 0 { return "MEH(\(basic(code)))" }
            let side = mods & 0x10 != 0 ? "R" : "L"
            return [(0x08, "GUI"), (0x04, "ALT"), (0x02, "SFT"), (0x01, "CTL")].filter { mods & UInt8($0.0) != 0 }
                .reduce(basic(code)) { "\(side)\($1.1)(\($0))" }
        default: break
        }
        guard protocolVersion >= VIAProtocol.keycodesV2 else { return nil }
        switch code {
        case 0x2000...0x3FFF: return "MT(\(modifierExpression(UInt8((code >> 8) & 0x1F))), \(basic(code)))"
        case 0x4000...0x4FFF: return "LT(\((code >> 8) & 0x0F), \(basic(code)))"
        case 0x52A0...0x52BF: return "OSM(\(modifierExpression(UInt8(code & 0x1F))))"
        default:
            for (fn, base) in layerFunctions where (base...base + 0x1F).contains(code) { return "\(fn)(\(code - base))" }
            return name(code)
        }
    }
}
