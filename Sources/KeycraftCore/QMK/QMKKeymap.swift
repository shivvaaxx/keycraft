import Foundation

/// QMK keymap.c in and out. Export writes each layer as the raw switch matrix, which QMK accepts in place of a
/// LAYOUT(...) macro, so it compiles for any board without knowing the macro's argument order. Import reads a
/// keymap.c as untrusted text: it never runs anything and throws on anything malformed.
public enum QMKKeymap {

    // MARK: Export

    public static func exportC(keymap: [[UInt16]], rows: Int, cols: Int, keyboardName: String,
                               vendorID: Int, productID: Int, protocolVersion: Int) -> String {
        var skipped = 0
        var out = """
        // \(keyboardName) (\(String(format: "%04X:%04X", vendorID, productID))), exported from Keycraft.
        //
        // Each layer is the keyboard's switch matrix, \(rows) rows by \(cols) columns, which QMK accepts in place
        // of a LAYOUT(...) macro. XXXXXXX marks matrix positions with no switch.
        //
        // To build it, copy this file into keyboards/<your keyboard>/keymaps/<name>/keymap.c in qmk_firmware.

        #include QMK_KEYBOARD_H

        const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {

        """
        for (layer, codes) in keymap.enumerated() {
            out += "    [\(layer)] = {\n"
            for row in 0..<rows {
                let names = (0..<cols).map { col -> String in
                    let i = row * cols + col
                    let code = i < codes.count ? codes[i] : 0
                    if let name = QMKNames.expression(code, protocolVersion: protocolVersion) { return name }
                    skipped += 1
                    return "XXXXXXX /* \(String(format: "0x%04X", code)) */"
                }
                out += "        { " + names.joined(separator: ", ") + " },\n"
            }
            out += "    },\n"
        }
        out += "};\n"
        if skipped > 0 {
            out += """

            // \(skipped) key(s) use older VIA keycodes that mean something else in current QMK; they are written as
            // XXXXXXX with the original code in a comment.

            """
        }
        return out
    }

    // MARK: Import

    public struct Key: Sendable, Hashable {
        /// The text as written, e.g. `LCTL_T(KC_A)` or `MY_MACRO`.
        public let text: String
        /// The keycode, when Keycraft knows what the text means.
        public let code: UInt16?
    }

    public struct Layer: Sendable {
        public let index: Int
        /// The name used in the file, e.g. `_BASE`, if it wasn't a plain number.
        public let name: String?
        /// `LAYOUT_60_ansi` and friends, or nil for a raw matrix.
        public let macro: String?
        /// Matrix form: one array per row. Macro form: a single array in the macro's argument order.
        public let rows: [[Key]]
    }

    public struct File: Sendable {
        public let layers: [Layer]
        /// Everything outside the keymaps array: custom keycodes, combos, tap dance, process_record_user...
        public let customCode: String
    }

    public enum ParseError: Error, Equatable, LocalizedError {
        case tooLarge, noKeymaps, unbalanced, malformed(String)
        public var errorDescription: String? {
            switch self {
            case .tooLarge: "The file is too large to be a keymap."
            case .noKeymaps: "No keymaps array was found in the file."
            case .unbalanced: "The file has unbalanced brackets."
            case .malformed(let what): "The keymap couldn't be read: \(what)."
            }
        }
    }

    static let maxFileSize = 512 * 1024
    static let maxLayers = 32
    static let maxKeysPerLayer = 255 * 4

    public static func parse(_ text: String) throws -> File {
        guard text.utf8.count <= maxFileSize else { throw ParseError.tooLarge }
        let source = stripComments(text)
        let defines = parseDefines(source)
        let enums = parseEnumValues(source)

        guard let header = source.range(of: #"keymaps\s*\[\s*\]\s*\[[^\]]*\]\s*\[[^\]]*\]\s*=\s*\{"#, options: .regularExpression)
        else { throw ParseError.noKeymaps }
        let bodyStart = header.upperBound
        let bodyEnd = try matchingClose(in: source, from: source.index(before: bodyStart))
        let body = String(source[bodyStart..<bodyEnd])
        let customCode = (String(source[..<header.lowerBound]) + String(source[source.index(after: bodyEnd)...]))
            .trimmingCharacters(in: .whitespacesAndNewlines)

        func resolve(_ token: String, depth: Int = 0) -> UInt16? {
            let t = token.trimmingCharacters(in: .whitespaces)
            if let c = QMKNames.code(t) { return c }
            if let n = integer(t) { return n <= 0xFFFF ? UInt16(n) : nil }
            if depth < 8, let value = defines[t] { return resolve(value, depth: depth + 1) }
            return composite(t, layer: { layerNumber($0) }, resolve: { resolve($0, depth: depth + 1) })
        }
        func layerNumber(_ token: String) -> Int? {
            let t = token.trimmingCharacters(in: .whitespaces)
            if let n = integer(t) { return n }
            if let n = enums[t] { return n }
            if let d = defines[t], let n = integer(d) { return n }
            return nil
        }

        var layers: [Layer] = []
        for (position, entry) in try splitTopLevel(body).enumerated() {
            let e = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !e.isEmpty else { continue }
            var index = position, name: String?, value = Substring(e)
            if e.hasPrefix("[") {
                guard let close = e.firstIndex(of: "]"), let eq = e[close...].firstIndex(of: "=") else { throw ParseError.malformed("layer \(position)") }
                let label = e[e.index(after: e.startIndex)..<close].trimmingCharacters(in: .whitespaces)
                guard let n = layerNumber(label) else { throw ParseError.malformed("unknown layer name \(label)") }
                index = n
                name = integer(label) == nil ? label : nil
                value = e[e.index(after: eq)...]
            }
            guard (0..<maxLayers).contains(index), !layers.contains(where: { $0.index == index }) else {
                throw ParseError.malformed("layer index \(index)")
            }
            let v = value.trimmingCharacters(in: .whitespacesAndNewlines)
            func keys(_ list: String) throws -> [Key] {
                try splitTopLevel(list).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    .map { Key(text: $0, code: resolve($0)) }
            }
            if v.hasPrefix("{") {
                let inner = try contents(of: v)
                let rows = try splitTopLevel(inner).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
                    .map { try keys(contents(of: $0)) }
                guard rows.reduce(0, { $0 + $1.count }) <= maxKeysPerLayer else { throw ParseError.malformed("layer \(index) is too large") }
                layers.append(Layer(index: index, name: name, macro: nil, rows: rows))
            } else if let open = v.firstIndex(of: "(") {
                let macro = v[..<open].trimmingCharacters(in: .whitespaces)
                guard macro.range(of: #"^[A-Za-z_][A-Za-z0-9_]*$"#, options: .regularExpression) != nil else {
                    throw ParseError.malformed("layer \(index)")
                }
                let close = try matchingClose(in: v, from: open)
                let list = try keys(String(v[v.index(after: open)..<close]))
                guard list.count <= maxKeysPerLayer else { throw ParseError.malformed("layer \(index) is too large") }
                layers.append(Layer(index: index, name: name, macro: macro, rows: [list]))
            } else {
                throw ParseError.malformed("layer \(index)")
            }
        }
        guard !layers.isEmpty else { throw ParseError.noKeymaps }
        return File(layers: layers.sorted { $0.index < $1.index }, customCode: customCode)
    }

    /// Where each key lands on this keyboard, by matrix position (row * cols + col). Matrix-form layers are exact;
    /// LAYOUT(...) layers are placed in the layout's key order, which is how most VIA definitions are written,
    /// so `isAssumed` is true and nil comes back when the counts differ.
    public static func placement(of layer: Layer, rows: Int, cols: Int, keyOrder: [(row: Int, col: Int)])
        -> (keys: [Int: Key], isAssumed: Bool)? {
        var placed: [Int: Key] = [:]
        if layer.macro == nil {
            guard layer.rows.count <= rows, layer.rows.allSatisfy({ $0.count <= cols }) else { return nil }
            for (r, row) in layer.rows.enumerated() { for (c, key) in row.enumerated() { placed[r * cols + c] = key } }
            return (placed, false)
        }
        guard let list = layer.rows.first, list.count == keyOrder.count else { return nil }
        for (key, pos) in zip(list, keyOrder) where pos.row < rows && pos.col < cols { placed[pos.row * cols + pos.col] = key }
        return (placed, true)
    }

    // MARK: Composite keys

    static func composite(_ t: String, layer: (String) -> Int?, resolve: (String) -> UInt16?) -> UInt16? {
        guard let open = t.firstIndex(of: "("), t.hasSuffix(")") else { return nil }
        let fn = t[..<open].trimmingCharacters(in: .whitespaces)
        guard let args = try? splitTopLevel(String(t[t.index(after: open)..<t.index(before: t.endIndex)])) else { return nil }
        func mods(_ s: String) -> UInt8? {
            var m: UInt8 = 0
            for part in s.split(separator: "|") {
                guard let v = QMKNames.modifierMasks[part.trimmingCharacters(in: .whitespaces)] else { return nil }
                m |= v
            }
            return m
        }
        func basic(_ s: String) -> UInt16? { resolve(s).flatMap { $0 <= 0xFF ? $0 : nil } }
        switch (fn, args.count) {
        case ("MT", 2):
            guard let m = mods(args[0]), let k = basic(args[1]) else { return nil }
            return 0x2000 | UInt16(m & 0x1F) << 8 | k
        case ("LT", 2):
            guard let n = layer(args[0]), (0...15).contains(n), let k = basic(args[1]) else { return nil }
            return 0x4000 | UInt16(n) << 8 | k
        case ("OSM", 1):
            return mods(args[0]).map { 0x52A0 | UInt16($0 & 0x1F) }
        case (_, 1) where QMKNames.layerFunctions[fn] != nil:
            guard let n = layer(args[0]), (0...31).contains(n) else { return nil }
            return QMKNames.layerFunctions[fn]! | UInt16(n)
        case (_, 1) where QMKNames.modTapShorthands[fn] != nil:
            return basic(args[0]).map { 0x2000 | UInt16(QMKNames.modTapShorthands[fn]!) << 8 | $0 }
        case (_, 1) where QMKNames.modifierWrappers[fn] != nil:
            // Wrappers nest (LCTL(LSFT(KC_A))); the inner key may already carry modifiers.
            guard let inner = resolve(args[0]), inner <= 0x1FFF else { return nil }
            return inner | UInt16(QMKNames.modifierWrappers[fn]!) << 8
        default:
            return nil
        }
    }

    // MARK: Text helpers (no regex over untrusted nesting; every scan is linear and bounded)

    static func stripComments(_ s: String) -> String {
        var out = "", i = s.startIndex
        var inString = false
        while i < s.endIndex {
            let c = s[i], next = s.index(after: i)
            if inString {
                out.append(c)
                if c == "\\", next < s.endIndex { out.append(s[next]); i = s.index(after: next); continue }
                if c == "\"" { inString = false }
                i = next
            } else if c == "\"" {
                inString = true; out.append(c); i = next
            } else if c == "/", next < s.endIndex, s[next] == "/" {
                i = s[next...].firstIndex(of: "\n") ?? s.endIndex
            } else if c == "/", next < s.endIndex, s[next] == "*" {
                i = s[s.index(after: next)...].range(of: "*/")?.upperBound ?? s.endIndex
                out.append(" ")
            } else {
                out.append(c); i = next
            }
        }
        return out
    }

    /// `#define NAME value` on one line, where NAME takes no arguments.
    static func parseDefines(_ s: String) -> [String: String] {
        var out: [String: String] = [:]
        for line in s.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("#define") else { continue }
            let parts = t.dropFirst(7).trimmingCharacters(in: .whitespaces).split(separator: " ", maxSplits: 1)
            guard parts.count == 2, !parts[0].contains("(") else { continue }
            out[String(parts[0])] = parts[1].trimmingCharacters(in: .whitespaces)
        }
        return out
    }

    /// Values of enum members that count from a plain number (layer enums). Enums that start at SAFE_RANGE or
    /// another symbol are custom keycodes, which have no fixed number, so they're skipped.
    static func parseEnumValues(_ s: String) -> [String: Int] {
        var out: [String: Int] = [:]
        var search = s.startIndex
        while let r = s.range(of: #"enum\b[^{;]*\{"#, options: .regularExpression, range: search..<s.endIndex) {
            guard let close = try? matchingClose(in: s, from: s.index(before: r.upperBound)) else { break }
            var next = 0, numeric = true
            for member in (try? splitTopLevel(String(s[r.upperBound..<close]))) ?? [] {
                let parts = member.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard let name = parts.first, !name.isEmpty else { continue }
                if parts.count == 2 {
                    if let v = integer(parts[1]) { next = v } else { numeric = false }
                }
                if numeric { out[name] = next }
                next += 1
            }
            search = close
        }
        return out
    }

    static func integer(_ t: String) -> Int? {
        let s = t.trimmingCharacters(in: .whitespaces)
        if s.lowercased().hasPrefix("0x") { return Int(s.dropFirst(2), radix: 16) }
        return Int(s)
    }

    /// Splits on commas that aren't inside (), {} or [].
    static func splitTopLevel(_ s: String) throws -> [String] {
        var parts: [String] = [], current = "", depth = 0
        for c in s {
            switch c {
            case "(", "{", "[": depth += 1
            case ")", "}", "]": depth -= 1; if depth < 0 { throw ParseError.unbalanced }
            default: break
            }
            if c == ",", depth == 0 { parts.append(current); current = "" } else { current.append(c) }
        }
        guard depth == 0 else { throw ParseError.unbalanced }
        parts.append(current)
        return parts
    }

    /// The index of the bracket that closes the one at `open`.
    static func matchingClose(in s: String, from open: String.Index) throws -> String.Index {
        var depth = 0, i = open
        while i < s.endIndex {
            switch s[i] {
            case "(", "{", "[": depth += 1
            case ")", "}", "]":
                depth -= 1
                if depth == 0 { return i }
                if depth < 0 { throw ParseError.unbalanced }
            default: break
            }
            i = s.index(after: i)
        }
        throw ParseError.unbalanced
    }

    /// Text between the outer braces of `{ ... }`.
    static func contents(of braced: String) throws -> String {
        let t = braced.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.first == "{", let close = try? matchingClose(in: t, from: t.startIndex), close == t.index(before: t.endIndex)
        else { throw ParseError.malformed("expected { ... }") }
        return String(t[t.index(after: t.startIndex)..<close])
    }
}
