import CoreGraphics
import Foundation

/// One keycap. `x`/`y`/`w`/`h` are the unrotated KLE rectangle; the key is then rotated `angle` degrees
/// clockwise about (`originX`, `originY`) (KLE's `r`, `rx`, `ry`). All in key units (1u = one standard key).
public struct PhysicalKey: Sendable, Hashable {
    public let row: Int
    public let col: Int
    public let x: Double
    public let y: Double
    public let w: Double
    public let h: Double
    public let angle: Double
    public let originX: Double
    public let originY: Double

    public init(row: Int, col: Int, x: Double, y: Double, w: Double, h: Double,
                angle: Double = 0, originX: Double = 0, originY: Double = 0) {
        (self.row, self.col, self.x, self.y, self.w, self.h) = (row, col, x, y, w, h)
        (self.angle, self.originX, self.originY) = (angle, originX, originY)
    }

    private func rotated(_ px: Double, _ py: Double) -> CGPoint {
        let (dx, dy, a) = (px - originX, py - originY, angle * .pi / 180)
        return CGPoint(x: originX + dx * cos(a) - dy * sin(a), y: originY + dx * sin(a) + dy * cos(a))
    }

    /// Where the cap's centre lands after rotation; draw an unrotated w x h cap here, then rotate it by `angle`.
    public var center: CGPoint { rotated(x + w / 2, y + h / 2) }
    public var corners: [CGPoint] { [rotated(x, y), rotated(x + w, y), rotated(x + w, y + h), rotated(x, y + h)] }
}

/// An entry of a definition's `customKeycodes`: entry i is keycode QK_KB + i.
public struct CustomKeycode: Sendable, Hashable, Decodable {
    public let name: String
    public let title: String
    public let shortName: String

    public init(name: String, title: String, shortName: String) { (self.name, self.title, self.shortName) = (name, title, shortName) }

    private enum CodingKeys: String, CodingKey { case name, title, shortName }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        let title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        self.init(name: name.isEmpty ? title : name, title: title, shortName: try c.decodeIfPresent(String.self, forKey: .shortName) ?? "")
    }
}

/// A VIA v2/v3 keyboard definition, reduced to what Keycraft needs.
public struct VIADefinition: Sendable, Decodable {
    public let name: String
    public let vendorID: Int
    public let productID: Int
    public let rows: Int
    public let cols: Int
    /// Titles of the layout-option groups (`layouts.labels`); informational for now.
    public let optionTitles: [String]
    /// Keys visible with every layout option at 0, in KLE coordinates, rotation described per key.
    public let keys: [PhysicalKey]
    public let customKeycodes: [CustomKeycode]

    /// Bounding box of all keys after rotation, in key units.
    public var bounds: CGRect {
        let points = keys.flatMap(\.corners)
        guard let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
              let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() else { return CGRect() }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    private enum CodingKeys: String, CodingKey { case name, vendorId, productId, matrix, layouts, customKeycodes }
    private struct Matrix: Decodable { let rows: Int; let cols: Int }
    private struct Layouts: Decodable { let keymap: [[KLEItem]]; let labels: [LabelItem]? }
    // `labels` entries are either "Title" (boolean option) or ["Title", "Choice 0", "Choice 1", ...].
    private enum LabelItem: Decodable {
        case title(String), choices([String])
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .title(s) } else { self = .choices(try c.decode([String].self)) }
        }
        var titleText: String { switch self { case .title(let t): t; case .choices(let c): c.first ?? "" } }
    }
    // KLE rows mix key labels (strings) with property objects. Only the properties that affect geometry are read.
    private enum KLEItem: Decodable {
        case label(String), props(KLEProps)
        init(from decoder: any Decoder) throws {
            let c = try decoder.singleValueContainer()
            if let s = try? c.decode(String.self) { self = .label(s) } else { self = .props(try c.decode(KLEProps.self)) }
        }
    }
    private struct KLEProps: Decodable {
        var x, y, w, h, r, rx, ry: Double?
        var d: Bool?
        private enum CodingKeys: String, CodingKey { case x, y, w, h, r, rx, ry, d }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // Tolerant: a malformed value in an unrelated-looking property must not sink the whole definition.
            x = try? c.decode(Double.self, forKey: .x); y = try? c.decode(Double.self, forKey: .y)
            w = try? c.decode(Double.self, forKey: .w); h = try? c.decode(Double.self, forKey: .h)
            r = try? c.decode(Double.self, forKey: .r); rx = try? c.decode(Double.self, forKey: .rx)
            ry = try? c.decode(Double.self, forKey: .ry); d = try? c.decode(Bool.self, forKey: .d)
        }
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        func hex(_ key: CodingKeys) throws -> Int {
            let s = try c.decode(String.self, forKey: key).trimmingCharacters(in: .whitespaces).lowercased()
            guard let v = Int(s.hasPrefix("0x") ? String(s.dropFirst(2)) : s, radix: 16) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Not a hex number: \(s)")
            }
            return v
        }
        vendorID = try hex(.vendorId)
        productID = try hex(.productId)
        let matrix = try c.decode(Matrix.self, forKey: .matrix)
        // VIA addresses rows and columns as single bytes. Layout files are untrusted (imported or downloaded),
        // and anything outside 1...255 would trap later (negative ranges, UInt8 conversions).
        guard (1...255).contains(matrix.rows), (1...255).contains(matrix.cols) else {
            throw DecodingError.dataCorruptedError(forKey: .matrix, in: c,
                debugDescription: "Matrix must have 1–255 rows and columns (found \(matrix.rows)×\(matrix.cols)).")
        }
        (rows, cols) = (matrix.rows, matrix.cols)
        let layouts = try c.decode(Layouts.self, forKey: .layouts)
        optionTitles = (layouts.labels ?? []).map(\.titleText)
        keys = Self.parseKLE(layouts.keymap, rows: matrix.rows, cols: matrix.cols)
        customKeycodes = try c.decodeIfPresent([CustomKeycode].self, forKey: .customKeycodes) ?? []
    }

    public init(data: Data) throws { self = try JSONDecoder().decode(VIADefinition.self, from: data) }

    /// KLE rules: `x`/`y` add to the cursor, `w`/`h`/`d` apply to the next key only, after a key x += w, after a
    /// row y += 1 and x = rx. `r`/`rx`/`ry` start a rotation cluster: rx and ry move the cursor to (rx, ry).
    /// Label line 0 = "row,col", line 3 = "group,option"; keys whose option isn't 0 are hidden. Decals and labels
    /// without a matrix position still advance the cursor.
    private static func parseKLE(_ kleRows: [[KLEItem]], rows: Int, cols: Int) -> [PhysicalKey] {
        func ints(_ s: Substring) -> [Int] { s.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
        var keys: [PhysicalKey] = []
        var y = 0.0, angle = 0.0, rx = 0.0, ry = 0.0
        for row in kleRows {
            var x = rx, w = 1.0, h = 1.0, decal = false
            for item in row {
                switch item {
                case .props(let p):
                    angle = p.r ?? angle
                    if let v = p.rx { rx = v; x = v }
                    if let v = p.ry { ry = v; y = v }
                    x += p.x ?? 0
                    y += p.y ?? 0
                    w = p.w ?? w
                    h = p.h ?? h
                    decal = p.d ?? decal
                case .label(let text):
                    defer { x += w; w = 1; h = 1; decal = false }
                    let lines = text.components(separatedBy: "\n")
                    let pos = ints(Substring(lines[0]))
                    guard !decal, pos.count == 2, (0..<rows).contains(pos[0]), (0..<cols).contains(pos[1]) else { continue }
                    if lines.count > 3 {
                        let option = ints(Substring(lines[3]))
                        if option.count == 2, option[1] != 0 { continue }
                    }
                    keys.append(PhysicalKey(row: pos[0], col: pos[1], x: x, y: y, w: w, h: h, angle: angle, originX: rx, originY: ry))
                }
            }
            y += 1
        }
        return keys
    }
}

extension VIADefinition {
    public static var defaultUserDirectory: URL {
        URL.applicationSupportDirectory.appending(path: "Keycraft/Definitions", directoryHint: .isDirectory)
    }

    /// Validates the file, then copies it into the user definitions folder as `<vid>-<pid>.json`.
    @discardableResult
    public static func importFile(_ url: URL, userDirectory: URL = defaultUserDirectory) throws -> VIADefinition {
        let data = try Data(contentsOf: url)
        let def = try VIADefinition(data: data)
        try FileManager.default.createDirectory(at: userDirectory, withIntermediateDirectories: true)
        try data.write(to: userDirectory.appending(path: String(format: "%04x-%04x.json", def.vendorID, def.productID)), options: .atomic)
        return def
    }
}
