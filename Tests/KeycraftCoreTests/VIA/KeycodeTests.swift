import Testing
@testable import KeycraftCore

@Suite struct KeycodeTests {
    @Test func basicNames() {
        #expect(Keycode.name(0x00) == "None" && Keycode.info(0x00).label == "—")
        #expect(Keycode.name(0x01) == "Transparent" && Keycode.info(0x01).label == "▽")
        #expect(Keycode.name(0x04) == "A" && Keycode.name(0x27) == "0" && Keycode.name(0x28) == "Enter" && Keycode.name(0x73) == "F24")
        #expect(Keycode.name(0xE0) == "Left Control" && Keycode.name(0xE1) == "Left Shift" && Keycode.name(0xE2) == "Left Option")
        #expect(Keycode.name(0xE3) == "Left Command" && Keycode.info(0xE3).label == "⌘" && Keycode.name(0xE7) == "Right Command")
    }

    @Test func mediaCodesMatchKeycodesH() {
        // keycodes.h: KC_AUDIO_MUTE 0xA8 ... KC_LAUNCHPAD 0xC2, KC_BRIGHTNESS_UP/DOWN 0xBD/0xBE
        #expect(Keycode.name(0xA8) == "Mute" && Keycode.name(0xA9) == "Volume Up" && Keycode.name(0xAE) == "Play/Pause")
        #expect(Keycode.name(0xBD) == "Brightness Up" && Keycode.name(0xBE) == "Brightness Down")
        #expect(Keycode.name(0xC1) == "Mission Control" && Keycode.name(0xC2) == "Launchpad" && Keycode.name(0xA5) == "System Power")
        #expect(Keycode.name(0x4C) == "Forward Delete" && Keycode.name(0x65) == "Application")
    }

    @Test func layerKeysUseExactWording() {
        let mo = Keycode.info(Keycode.momentary(2)), to = Keycode.info(Keycode.to(1)), tg = Keycode.info(Keycode.toggle(3))
        #expect(mo.name == "Hold for Layer 2" && mo.description == "Layer 2 is active only while you hold this key")
        #expect(to.name == "Switch to Layer 1" && to.description == "Stays on Layer 1 until you switch again")
        #expect(tg.name == "Toggle Layer 3" && tg.description == "Press once to turn Layer 3 on, again to turn it off")
        #expect(mo.label == "Hold L2")
        let base = Keycode.info(Keycode.momentary(0))
        #expect(base.name == "Hold for Base" && base.description == "Base is active only while you hold this key" && base.label == "Hold Base")
        #expect(Keycode.layerName(0) == "Base" && Keycode.layerName(2) == "Layer 2")
        // ranges: QK_TO 0x5200, QK_MOMENTARY 0x5220, QK_TOGGLE_LAYER 0x5260, 32 layers each
        #expect(Keycode.momentary(2) == 0x5222 && Keycode.toggle(1) == 0x5261 && Keycode.to(0) == 0x5200)
        #expect(Keycode.name(0x523F) == "Hold for Layer 31" && Keycode.name(0x527F) == "Toggle Layer 31" && Keycode.name(0x521F) == "Switch to Layer 31")
    }

    @Test func unknownCodesAreCustomCodes() {
        let c = Keycode.info(0x7C16)
        #expect(c.name == "Custom code 0x7C16" && c.description == "Set by the keyboard's firmware" && c.label == "0x7C16")
        #expect(Keycode.name(0x0003) == "Custom code 0x0003")
        #expect(Keycode.name(0x5240) == "Custom code 0x5240")   // QK_DEF_LAYER: not offered
        #expect(Keycode.name(0x7E05) == "Custom code 0x7E05")   // QK_KB beyond the definition's list
    }

    @Test func oldProtocolsOnlyNameBasicCodes() {
        #expect(Keycode.name(0x04, protocolVersion: 9) == "A")
        #expect(Keycode.name(0x5222, protocolVersion: 9) == "Custom code 0x5222")
    }

    @Test func customKeycodesMapToQKKB() {
        let custom = [CustomKeycode(name: "Mission Control", title: "Open Mission Control", shortName: "Mis Ctrl"),
                      CustomKeycode(name: "Launchpad", title: "Open Launchpad", shortName: "")]
        #expect(Keycode.qkKB == 0x7E00 && Keycode.qkKBMax == 0x7E3F)
        let first = Keycode.info(0x7E00, custom: custom), second = Keycode.info(0x7E01, custom: custom)
        #expect(first.label == "Mis Ctrl" && first.name == "Mission Control" && first.description == "Open Mission Control")
        #expect(second.label == "Launchpad")
        #expect(Keycode.name(0x7E02, custom: custom) == "Custom code 0x7E02")
        let groups = Keycode.catalogue(layerCount: 4, custom: custom)
        #expect(groups[0].title == "This Keyboard" && groups[0].keycodes.map(\.code) == [0x7E00, 0x7E01])
    }

    @Test func catalogueGroupsAndLayerLimit() {
        let groups = Keycode.catalogue(layerCount: 3)
        #expect(groups.map(\.title) == ["Letters & Numbers", "Symbols", "Editing", "Navigation", "Function Keys", "Modifiers",
                                        "Media & System", "Keypad", "Layers", "One-Shot", "Special"])
        #expect(groups.dropFirst().allSatisfy { !$0.footer.isEmpty })   // letters need no footer
        #expect([0x04, 0x28, 0xA9, 0xE3].allSatisfy { !Keycode.needsExplanation($0) })      // A, Enter, Volume Up, Command
        #expect([0x00, 0x01, 0x46, Keycode.momentary(1), Keycode.qkKB].allSatisfy(Keycode.needsExplanation))
        #expect(groups.filter(\.isPlain).map(\.title) == ["Letters & Numbers", "Symbols", "Function Keys", "Keypad"])
        let layers = groups.first { $0.title == "Layers" }!.keycodes.map(\.name)
        #expect(layers.count == 9 && layers.contains("Hold for Layer 2") && !layers.contains("Hold for Layer 3"))
        #expect(Array(layers.prefix(3)) == ["Hold for Base", "Switch to Base", "Toggle Base"])
        #expect(groups.first { $0.title == "Special" }!.keycodes.map(\.code) == [0x00, 0x01])
        #expect(groups.first { $0.title == "Letters & Numbers" }!.keycodes.count == 36)
        #expect(groups.first { $0.title == "Function Keys" }!.keycodes.count == 24)
        #expect(Keycode.catalogue(layerCount: 4, protocolVersion: 9).contains { $0.title == "Layers" } == false)
    }

    @Test func everyCatalogueAndTableEntryHasNameAndShortDescription() {
        let catalogue = Keycode.catalogue(layerCount: 32).flatMap(\.keycodes)
        let all = catalogue + Keycode.table.values
        #expect(all.count > 200)
        for k in all {
            #expect(!k.name.isEmpty && !k.label.isEmpty, "code \(k.code) needs a name and label")
            #expect(!k.description.isEmpty && k.description.count <= 75, "code \(k.code) description: \(k.description)")
            #expect(!k.name.hasPrefix("Custom code"), "code \(k.code) fell back to a custom code")
        }
        #expect(Set(catalogue.map(\.code)).count == catalogue.count)   // no code listed twice
    }

    @Test func tapHoldMatchesQMKEncoding() {
        // keycodes.h: MT(MOD_LCTL, KC_A) = 0x2104, LT(1, KC_ESC) = 0x4129, LGUI(KC_C) = 0x0806, OSM(MOD_LSFT) = 0x52A2.
        #expect(Keycode.tapHold(tap: 0x04, hold: .modifiers(Keycode.Modifier.control)) == 0x2104)
        #expect(Keycode.tapHold(tap: 0x29, hold: .layer(1)) == 0x4129)
        #expect(Keycode.withModifiers(Keycode.Modifier.command, key: 0x06) == 0x0806)
        #expect(Keycode.oneShotModifier(Keycode.Modifier.shift) == 0x52A2 && Keycode.oneShotLayer(2) == 0x5282)
        #expect(Keycode.tapHold(0x2104)! == (0x04, .modifiers(0x01)) && Keycode.tapHold(0x4129)! == (0x29, .layer(1)))
        #expect(Keycode.tapHold(0x2104, protocolVersion: 11) == nil && Keycode.tapHold(0x5220) == nil)

        #expect(Keycode.info(0x2104).name == "A, hold for Control" && Keycode.info(0x2104).label == "A/⌃")
        #expect(Keycode.info(0x4129).name == "Escape, hold for Layer 1")
        #expect(Keycode.info(0x0806).name == "Command+C" && Keycode.info(0x0806).label == "⌘C")
        #expect(Keycode.info(0x0F00).name == "Hyper" && Keycode.info(0x0700).name == "Meh")
        #expect(Keycode.info(0x1200).name == "Right Shift")
        #expect(Keycode.info(0x52A2).name == "One-Shot Shift" && Keycode.info(0x5281).name == "One-Shot Layer 1")
        #expect(Keycode.info(0x2F04).name == "A, hold for Hyper")
    }
}
