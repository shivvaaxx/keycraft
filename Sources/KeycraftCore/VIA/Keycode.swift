import Foundation

public struct KeycodeInfo: Sendable, Hashable, Identifiable {
    public let code: UInt16
    public let label: String        // short, for the keycap
    public let name: String         // full, for the picker and VoiceOver
    public let description: String  // one plain-English line (<= 75 characters for built-in codes)
    public var id: UInt16 { code }
}

public struct KeycodeGroup: Sendable, Identifiable {
    public let title: String
    public let footer: String
    public let keycodes: [KeycodeInfo]
    public var id: String { title }
    public init(title: String, footer: String = "", keycodes: [KeycodeInfo]) { (self.title, self.footer, self.keycodes) = (title, footer, keycodes) }
}

/// Codes and ranges follow QMK keycodes.h: KC_ block 0x0000-0x00C2 and 0x00E0-0x00E7, QK_TO 0x5200-0x521F,
/// QK_MOMENTARY 0x5220-0x523F, QK_TOGGLE_LAYER 0x5260-0x527F, QK_KB 0x7E00-0x7E3F.
public enum Keycode {
    public static let none: UInt16 = 0x00
    public static let transparent: UInt16 = 0x01
    public static let qkKB: UInt16 = 0x7E00
    public static let qkKBMax: UInt16 = 0x7E3F
    /// Layer 0 is "Base"; the rest are "Layer N".
    public static func layerName(_ layer: Int) -> String { layer == 0 ? "Base" : "Layer \(layer)" }
    public static func to(_ layer: Int) -> UInt16 { 0x5200 | UInt16(layer) }
    public static func momentary(_ layer: Int) -> UInt16 { 0x5220 | UInt16(layer) }
    public static func toggle(_ layer: Int) -> UInt16 { 0x5260 | UInt16(layer) }

    public static func info(_ code: UInt16, protocolVersion: Int = VIAProtocol.keycodesV2, custom: [CustomKeycode] = []) -> KeycodeInfo {
        if (qkKB...qkKBMax).contains(code), Int(code - qkKB) < custom.count {
            let c = custom[Int(code - qkKB)]
            return KeycodeInfo(code: code, label: c.shortName.isEmpty ? c.name : c.shortName, name: c.name, description: c.title)
        }
        if let known = table[code] { return known }
        if protocolVersion >= VIAProtocol.keycodesV2 {
            for (base, kind) in [(UInt16(0x5200), LayerKind.to), (0x5220, .momentary), (0x5260, .toggle)] where (base...base + 0x1F).contains(code) {
                return layerInfo(kind, Int(code - base))
            }
        }
        let hex = String(format: "0x%04X", code)
        return KeycodeInfo(code: code, label: hex, name: "Custom code \(hex)", description: "Set by the keyboard's firmware")
    }

    public static func name(_ code: UInt16, protocolVersion: Int = VIAProtocol.keycodesV2, custom: [CustomKeycode] = []) -> String {
        info(code, protocolVersion: protocolVersion, custom: custom).name
    }

    /// Picker contents. Layer keys only for v2 keycodes and only for layers that exist (max 32 fit the ranges).
    public static func catalogue(layerCount: Int, protocolVersion: Int = VIAProtocol.keycodesV2, custom: [CustomKeycode] = []) -> [KeycodeGroup] {
        func group(_ title: String, _ footer: String, _ codes: [UInt16]) -> KeycodeGroup {
            KeycodeGroup(title: title, footer: footer, keycodes: codes.map { info($0, protocolVersion: protocolVersion) })
        }
        func range(_ r: ClosedRange<UInt16>) -> [UInt16] { Array(r) }
        var groups: [KeycodeGroup] = []
        if !custom.isEmpty {
            let codes = custom.indices.map { qkKB + UInt16($0) }
            groups.append(KeycodeGroup(title: "This Keyboard", footer: "Extra keys that this keyboard's own firmware provides.",
                                       keycodes: codes.map { info($0, protocolVersion: protocolVersion, custom: custom) }))
        }
        groups += [
            group("Letters & Numbers", "Types the letter or number on the cap.", range(0x04...0x1D) + range(0x1E...0x27)),
            group("Symbols", "Punctuation keys. Which character appears depends on your keyboard layout in macOS.",
                  [0x2D, 0x2E, 0x2F, 0x30, 0x31, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x32, 0x64]),
            group("Editing", "Keys for entering, deleting and managing text.",
                  [0x28, 0x29, 0x2A, 0x4C, 0x2B, 0x2C, 0x39, 0x49, 0x65, 0x7A, 0x7B, 0x7C, 0x7D, 0x7E]),
            group("Navigation", "Move the cursor or scroll through a document.", [0x52, 0x51, 0x50, 0x4F, 0x4A, 0x4D, 0x4B, 0x4E]),
            group("Function Keys", "F1 to F24. Apps and macOS decide what these do.", range(0x3A...0x45) + range(0x68...0x73)),
            group("Modifiers", "Hold one of these while pressing another key to make shortcuts.", range(0xE0...0xE7)),
            group("Media & System", "Volume, playback, brightness and other controls that work across the whole Mac.",
                  range(0xA8...0xB0) + [0xBB, 0xBC, 0xBD, 0xBE, 0xC1, 0xC2, 0xC0, 0xA5, 0xA6, 0xA7, 0x46, 0x47, 0x48]
                  + [0xB1, 0xB2, 0xB3, 0xB4, 0xB5, 0xB6, 0xB7, 0xB8, 0xB9, 0xBA, 0xBF]),
            group("Keypad", "Number pad keys.", [0x53, 0x54, 0x55, 0x56, 0x57, 0x58] + range(0x59...0x62) + [0x63, 0x67, 0x85]),
        ]
        if protocolVersion >= VIAProtocol.keycodesV2 {
            let layers = (0..<min(max(layerCount, 0), 32)).flatMap { [momentary($0), to($0), toggle($0)] }
            groups.append(group("Layers", "Layers hold extra sets of keys. Use these to move between them.", layers))
        }
        groups.append(group("Special", "Keys that do nothing themselves.", [none, transparent]))
        return groups
    }

    // MARK: Layer keys

    private enum LayerKind { case momentary, to, toggle }

    private static func layerInfo(_ kind: LayerKind, _ n: Int) -> KeycodeInfo {
        let layer = layerName(n)
        let short = n == 0 ? "Base" : "L\(n)"
        switch kind {
        case .momentary:
            return KeycodeInfo(code: momentary(n), label: "Hold \(short)", name: "Hold for \(layer)", description: "\(layer) is active only while you hold this key")
        case .to:
            return KeycodeInfo(code: to(n), label: "To \(short)", name: "Switch to \(layer)", description: "Stays on \(layer) until you switch again")
        case .toggle:
            return KeycodeInfo(code: toggle(n), label: "Tgl \(short)", name: "Toggle \(layer)", description: "Press once to turn \(layer) on, again to turn it off")
        }
    }

    // MARK: Built-in table

    /// Every code the app can name. Checked against keycodes.h by KeycodeTests.
    static let table: [UInt16: KeycodeInfo] = {
        var t: [UInt16: KeycodeInfo] = [:]
        func put(_ code: UInt16, _ label: String, _ name: String, _ description: String) {
            t[code] = KeycodeInfo(code: code, label: label, name: name, description: description)
        }
        put(0x00, "—", "None", "Key does nothing")
        put(0x01, "▽", "Transparent", "Uses the key from the layer below")
        for (i, ch) in "ABCDEFGHIJKLMNOPQRSTUVWXYZ".enumerated() { put(0x04 + UInt16(i), String(ch), String(ch), "Types the letter \(ch)") }
        for (i, ch) in "1234567890".enumerated() { put(0x1E + UInt16(i), String(ch), String(ch), "Types the number \(ch)") }
        put(0x28, "↩", "Enter", "Starts a new line or confirms"); put(0x29, "⎋", "Escape", "Cancels or closes what you are doing")
        put(0x2A, "⌫", "Backspace", "Deletes the character before the cursor"); put(0x2B, "⇥", "Tab", "Moves to the next field or inserts a tab")
        put(0x2C, "␣", "Space", "Types a space"); put(0x39, "⇪", "Caps Lock", "Types capital letters until you press it again")
        put(0x4C, "⌦", "Forward Delete", "Deletes the character after the cursor"); put(0x49, "Ins", "Insert", "Switches between inserting and overwriting text")
        put(0x65, "Menu", "Application", "Opens the context menu, like a right-click")
        put(0x2D, "-", "Minus", "Types a minus sign (hyphen)"); put(0x2E, "=", "Equals", "Types an equals sign")
        put(0x2F, "[", "Left Bracket", "Types a left square bracket"); put(0x30, "]", "Right Bracket", "Types a right square bracket")
        put(0x31, "\\", "Backslash", "Types a backslash"); put(0x33, ";", "Semicolon", "Types a semicolon")
        put(0x34, "'", "Quote", "Types an apostrophe or quote mark"); put(0x35, "`", "Grave", "Types a backtick (grave accent)")
        put(0x36, ",", "Comma", "Types a comma"); put(0x37, ".", "Period", "Types a period"); put(0x38, "/", "Slash", "Types a forward slash")
        put(0x32, "#", "Non-US Hash", "Types # on keyboards with an international layout")
        put(0x64, "\\", "Non-US Backslash", "The extra backslash key on international layouts")
        for i in 0..<12 {
            put(0x3A + UInt16(i), "F\(i + 1)", "F\(i + 1)", "Function key \(i + 1). Apps and macOS decide what it does")
            put(0x68 + UInt16(i), "F\(i + 13)", "F\(i + 13)", "Function key \(i + 13). Apps and macOS decide what it does")
        }
        put(0x46, "PrtSc", "Print Screen", "Print Screen key; macOS does not use it by default")
        put(0x47, "ScrLk", "Scroll Lock", "Scroll Lock key; rarely used on a Mac")
        put(0x48, "Pause", "Pause", "Pause key; rarely used on a Mac")
        put(0x4A, "Home", "Home", "Jumps to the start of a line or document")
        put(0x4D, "End", "End", "Jumps to the end of a line or document")
        put(0x4B, "PgUp", "Page Up", "Scrolls up one screen"); put(0x4E, "PgDn", "Page Down", "Scrolls down one screen")
        put(0x4F, "→", "Right Arrow", "Moves right"); put(0x50, "←", "Left Arrow", "Moves left")
        put(0x51, "↓", "Down Arrow", "Moves down"); put(0x52, "↑", "Up Arrow", "Moves up")
        // Keypad
        put(0x53, "Num", "Num Lock", "Switches the number pad between numbers and navigation")
        for (c, s, n) in [(0x54, "/", "Divide"), (0x55, "*", "Multiply"), (0x56, "-", "Minus"), (0x57, "+", "Plus"),
                          (0x58, "Enter", "Enter"), (0x63, ".", "Decimal Point"), (0x67, "=", "Equals"),
                          (0x85, ",", "Comma")] as [(UInt16, String, String)] {
            put(c, "KP \(s)", "Keypad \(n)", "\(n) key on the number pad")
        }
        for i in 1...9 { put(0x58 + UInt16(i), "KP \(i)", "Keypad \(i)", "Types \(i) on the number pad") }
        put(0x62, "KP 0", "Keypad 0", "Types 0 on the number pad")
        // Less common basic keys
        put(0x66, "Power", "Keyboard Power", "Power key from the keyboard; macOS usually ignores it")
        for (c, n, d) in [(0x74, "Execute", "Runs the selected command"), (0x75, "Help", "Opens help in the current app"),
                          (0x76, "Menu (Legacy)", "Opens a menu in some apps"), (0x77, "Select", "Selects the current item"),
                          (0x78, "Stop", "Stops the current action"), (0x79, "Again", "Repeats the last action"),
                          (0x7A, "Undo", "Undoes the last action"), (0x7B, "Cut", "Cuts the selection"),
                          (0x7C, "Copy", "Copies the selection"), (0x7D, "Paste", "Pastes what you copied"),
                          (0x7E, "Find", "Starts a search"), (0x7F, "Mute (Keyboard)", "Mutes the sound, as a keyboard key"),
                          (0x80, "Volume Up (Keyboard)", "Raises the volume, as a keyboard key"),
                          (0x81, "Volume Down (Keyboard)", "Lowers the volume, as a keyboard key"),
                          (0x82, "Locking Caps Lock", "Caps Lock that stays on until switched off"),
                          (0x83, "Locking Num Lock", "Num Lock that stays on until switched off"),
                          (0x84, "Locking Scroll Lock", "Scroll Lock that stays on until switched off"),
                          (0x86, "Keypad = (AS/400)", "Equals key from AS/400 keypads"),
                          (0x99, "Alternate Erase", "Erases the previous entry"), (0x9A, "System Request", "System request key"),
                          (0x9B, "Cancel", "Cancels the current action"), (0x9C, "Clear", "Clears the current entry"),
                          (0x9D, "Prior", "Goes to the previous item"), (0x9E, "Return", "Return key from the HID standard"),
                          (0x9F, "Separator", "Separator key from the HID standard"), (0xA0, "Out", "Out key from the HID standard"),
                          (0xA1, "Oper", "Oper key from the HID standard"), (0xA2, "Clear Again", "Clears the current entry again"),
                          (0xA3, "CrSel", "CrSel key from the HID standard"), (0xA4, "ExSel", "ExSel key from the HID standard")]
                          as [(UInt16, String, String)] { put(c, n, n, d) }
        for i in 1...9 {
            put(0x86 + UInt16(i), "Intl \(i)", "International \(i)", "Extra key used on some international keyboards")
            put(0x8F + UInt16(i), "Lang \(i)", "Language \(i)", "Language switch key used on some keyboards")
        }
        // Media & System: system and consumer usages 0xA5-0xC2 (keycodes.h KC_SYSTEM_POWER ... KC_LAUNCHPAD)
        for (c, l, n, d) in [(0xA5, "Power", "System Power", "Shuts down or puts the Mac to sleep"),
                             (0xA6, "Sleep", "System Sleep", "Puts the Mac to sleep"),
                             (0xA7, "Wake", "System Wake", "Wakes the Mac"),
                             (0xA8, "Mute", "Mute", "Mutes or unmutes the sound"),
                             (0xA9, "Vol+", "Volume Up", "Raises the volume"),
                             (0xAA, "Vol−", "Volume Down", "Lowers the volume"),
                             (0xAB, "Next", "Next Track", "Skips to the next song or video"),
                             (0xAC, "Prev", "Previous Track", "Goes back to the previous song or video"),
                             (0xAD, "Stop", "Media Stop", "Stops playback"),
                             (0xAE, "Play", "Play/Pause", "Plays or pauses the current media"),
                             (0xAF, "Media", "Media Select", "Opens the media player"),
                             (0xB0, "Eject", "Eject", "Ejects a disc or drive"),
                             (0xB1, "Mail", "Mail", "Opens the email app"),
                             (0xB2, "Calc", "Calculator", "Opens the Calculator"),
                             (0xB3, "My PC", "My Computer", "Opens the file browser; rarely used on a Mac"),
                             (0xB4, "Search", "Web Search", "Opens a web search"),
                             (0xB5, "Home", "Web Home", "Goes to the browser's home page"),
                             (0xB6, "Back", "Web Back", "Goes back one page in the browser"),
                             (0xB7, "Fwd", "Web Forward", "Goes forward one page in the browser"),
                             (0xB8, "Stop", "Web Stop", "Stops loading the page"),
                             (0xB9, "Refresh", "Web Refresh", "Reloads the page"),
                             (0xBA, "Fav", "Web Favorites", "Opens bookmarks or favorites"),
                             (0xBB, "FF", "Fast Forward", "Fast-forwards the current media"),
                             (0xBC, "Rew", "Rewind", "Rewinds the current media"),
                             (0xBD, "Bri+", "Brightness Up", "Makes the display brighter"),
                             (0xBE, "Bri−", "Brightness Down", "Makes the display dimmer"),
                             (0xBF, "Ctrl Panel", "Control Panel", "Opens settings; rarely used on a Mac"),
                             (0xC0, "Assist", "Assistant", "Starts the voice assistant, such as Siri"),
                             (0xC1, "Mission", "Mission Control", "Shows all open windows and desktops"),
                             (0xC2, "Launch", "Launchpad", "Shows all your apps")] as [(UInt16, String, String, String)] {
            put(c, l, n, d)
        }
        // Modifiers with Mac names (keycodes.h KC_LEFT_CTRL = 0xE0 ... KC_RIGHT_GUI = 0xE7)
        for (i, (symbol, name)) in [("⌃", "Control"), ("⇧", "Shift"), ("⌥", "Option"), ("⌘", "Command")].enumerated() {
            put(0xE0 + UInt16(i), symbol, "Left \(name)", "Hold with other keys for shortcuts (left \(name))")
            put(0xE4 + UInt16(i), "R\(symbol)", "Right \(name)", "Hold with other keys for shortcuts (right \(name))")
        }
        return t
    }()
}
