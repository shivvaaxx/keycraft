import Foundation
import Testing
@testable import KeycraftCore

/// Writes a sample export when KEYCRAFT_QMK_SAMPLE is set, so it can be compiled with `qmk compile` by hand.
@Suite struct QMKExportSampleTests {
    @Test func writeSample() throws {
        guard let path = ProcessInfo.processInfo.environment["KEYCRAFT_QMK_SAMPLE"] else { return }
        var all = Keycode.catalogue(layerCount: 4).flatMap(\.keycodes).map(\.code)
        all += [0x2104, 0x4129, 0x0306, 0x0F04, 0x1104, 0x2F04, 0x3239]
        let perLayer = 5 * 14
        let layers = stride(from: 0, to: all.count, by: perLayer).map { Array(all[$0..<min($0 + perLayer, all.count)]) }
        let c = QMKKeymap.exportC(keymap: layers, rows: 5, cols: 14, keyboardName: "GH60 Satan", vendorID: 0x4335,
                                  productID: 0x0002, protocolVersion: 12)
        try c.write(toFile: path, atomically: true, encoding: .utf8)
    }
}
