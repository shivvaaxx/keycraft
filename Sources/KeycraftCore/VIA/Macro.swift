import Foundation

/// One step of a VIA macro. Keys are basic keycodes (0x04-0xFF): the macro format stores one byte per key.
public enum MacroStep: Hashable, Sendable {
    case text(String)       // typed as if on a US keyboard, like QMK's SEND_STRING
    case tap(UInt8)
    case down(UInt8)
    case up(UInt8)
    case delay(Int)         // milliseconds
}

/// VIA's macro buffer: every macro is a NUL-terminated string, one after another. Plain bytes are typed as text;
/// `0x01` starts an action: `01 01 kc` tap, `01 02 kc` press, `01 03 kc` release, `01 04 <digits> |` wait.
/// Firmware: quantum/send_string/send_string.c send_string_with_delay_impl, quantum/dynamic_keymap.c
/// dynamic_keymap_macro_send. This is the encoding VIA uses from protocol 11.
public enum Macros {
    public static let minimumProtocol = 11
    /// QK_MACRO 0x7700-0x777F (v2 keycodes).
    public static let firstKeycode: UInt16 = 0x7700
    public static let lastKeycode: UInt16 = 0x777F
    public static func keycode(_ index: Int) -> UInt16 { firstKeycode + UInt16(index) }
    public static func index(of code: UInt16) -> Int? { (firstKeycode...lastKeycode).contains(code) ? Int(code - firstKeycode) : nil }

    private static let prefix: UInt8 = 0x01
    private enum Action: UInt8 { case tap = 1, down = 2, up = 3, delay = 4 }

    /// The first `count` macros in `buffer`. Missing ones (buffer ends early) are empty.
    public static func decode(_ buffer: [UInt8], count: Int) -> [[MacroStep]] {
        var macros: [[MacroStep]] = []
        var i = 0
        while macros.count < count {
            var steps: [MacroStep] = []
            var text = ""
            func flush() { if !text.isEmpty { steps.append(.text(text)); text = "" } }
            while i < buffer.count, buffer[i] != 0 {
                let b = buffer[i]; i += 1
                guard b == prefix else { text.append(Character(Unicode.Scalar(b))); continue }
                flush()
                guard i < buffer.count, let action = Action(rawValue: buffer[i]) else { i += 1; continue }
                i += 1
                switch action {
                case .delay:
                    var ms = 0
                    while i < buffer.count, (0x30...0x39).contains(buffer[i]) { ms = ms * 10 + Int(buffer[i] - 0x30); i += 1 }
                    if i < buffer.count, buffer[i] != 0 { i += 1 }   // the terminator ('|') is consumed by firmware too
                    steps.append(.delay(ms))
                case .tap, .down, .up:
                    guard i < buffer.count, buffer[i] != 0 else { continue }
                    let kc = buffer[i]; i += 1
                    steps.append(action == .tap ? .tap(kc) : action == .down ? .down(kc) : .up(kc))
                }
            }
            flush()
            macros.append(steps)
            i += 1   // past the NUL
        }
        return macros
    }

    /// Every macro NUL-terminated, in order. Text keeps only characters QMK can type (printable ASCII, tab, newline).
    public static func encode(_ macros: [[MacroStep]]) -> [UInt8] {
        var out: [UInt8] = []
        for steps in macros {
            for step in steps {
                switch step {
                case .text(let s): out += s.unicodeScalars.filter(isTypeable).map { UInt8($0.value) }
                case .tap(let kc) where kc != 0: out += [prefix, Action.tap.rawValue, kc]
                case .down(let kc) where kc != 0: out += [prefix, Action.down.rawValue, kc]
                case .up(let kc) where kc != 0: out += [prefix, Action.up.rawValue, kc]
                case .delay(let ms): out += [prefix, Action.delay.rawValue] + Array(String(max(0, ms)).utf8) + [UInt8(ascii: "|")]
                default: break
                }
            }
            out.append(0)
        }
        return out
    }

    public static func isTypeable(_ s: Unicode.Scalar) -> Bool { (0x20...0x7E).contains(s.value) || s == "\t" || s == "\n" }

    /// Tidies recorded key events: a press and release of the same key with nothing between becomes a tap, and
    /// taps of plain letters, digits and space with no modifier held become text.
    public static func simplify(_ steps: [MacroStep]) -> [MacroStep] {
        var out: [MacroStep] = []
        var held = Set<UInt8>()
        for step in steps {
            switch step {
            case .down(let kc) where isModifier(kc): held.insert(kc)
            case .up(let kc) where isModifier(kc): held.remove(kc)
            default: break
            }
            if case .up(let kc) = step, case .down(kc) = out.last {
                out.removeLast()
                let char = held.isEmpty ? textCharacter(kc) : nil
                out.append(char.map { .text(String($0)) } ?? .tap(kc))
            } else {
                out.append(step)
            }
            if out.count >= 2, case .text(let b) = out[out.count - 1], case .text(let a) = out[out.count - 2] {
                out.removeLast(2)
                out.append(.text(a + b))
            }
        }
        return out
    }

    public static func isModifier(_ kc: UInt8) -> Bool { (0xE0...0xE7).contains(kc) }

    /// A key that types the same character on a US layout with no modifier held: a-z, 1-0, space.
    private static func textCharacter(_ kc: UInt8) -> Character? {
        switch kc {
        case 0x04...0x1D: Character(Unicode.Scalar(UInt8(ascii: "a") + kc - 0x04))
        case 0x1E...0x26: Character(Unicode.Scalar(UInt8(ascii: "1") + kc - 0x1E))
        case 0x27: "0"
        case 0x2C: " "
        default: nil
        }
    }

    /// A short plain-English summary, e.g. "⌘Space, wait 300 ms, “Safari”, Enter". Modifiers held around a key
    /// read as one shortcut.
    public static func summary(_ steps: [MacroStep]) -> String {
        guard !steps.isEmpty else { return "Empty" }
        var parts: [String] = []
        var held: [UInt8] = []
        var usedHeld = false
        func label(_ kc: UInt8) -> String { Keycode.info(UInt16(kc)).label }
        for step in steps {
            let prefix = held.map(label).joined()
            switch step {
            case .text(let s):
                parts.append(prefix + "“\(s.replacingOccurrences(of: "\n", with: "⏎"))”"); usedHeld = true
            case .tap(let kc): parts.append(prefix + label(kc)); usedHeld = true
            case .down(let kc) where isModifier(kc): held.append(kc); usedHeld = false
            case .down(let kc): parts.append("hold " + prefix + label(kc))
            case .up(let kc) where isModifier(kc):
                if !usedHeld { parts.append(prefix) }   // a modifier pressed on its own
                held.removeAll { $0 == kc }; usedHeld = true
            case .up(let kc): parts.append("release " + label(kc))
            case .delay(let ms): parts.append("wait \(ms) ms")
            }
        }
        return parts.joined(separator: ", ")
    }
}
