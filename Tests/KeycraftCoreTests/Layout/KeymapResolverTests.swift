import Testing
@testable import KeycraftCore

struct KeymapResolverTests {
    private let keymap: [[UInt16]] = [[0x04, 0x05, 0x06], [0x01, 0x10, 0x01], [0x01, 0x01, 0x07]]

    @Test func ownCodeIsNotInherited() {
        let r = KeymapResolver.effective(keymap: keymap, layer: 1, position: 1)
        #expect(r.code == 0x10 && !r.inherited)
    }

    @Test func transparentFallsThroughToLowerLayers() {
        #expect(KeymapResolver.effective(keymap: keymap, layer: 2, position: 0) == (0x04, true))   // 2 -> 1 -> 0
        #expect(KeymapResolver.effective(keymap: keymap, layer: 2, position: 1) == (0x10, true))   // 2 -> 1
        #expect(KeymapResolver.effective(keymap: keymap, layer: 1, position: 2) == (0x06, true))
    }

    @Test func transparentAtBaseStaysTransparentAndOutOfRangeIsNone() {
        #expect(KeymapResolver.effective(keymap: [[0x01]], layer: 0, position: 0) == (0x01, false))
        #expect(KeymapResolver.effective(keymap: keymap, layer: 9, position: 0) == (0x00, false))
    }
}
