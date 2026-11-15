import Foundation
import Testing
@testable import KeycraftCore

@Suite struct QMKKeymapTests {
    @Test func namesComeFromQMK() {
        #expect(QMKNames.name(0x04) == "KC_A" && QMKNames.name(0x28) == "KC_ENT" && QMKNames.name(0xE0) == "KC_LCTL")
        #expect(QMKNames.name(0x00) == "XXXXXXX" && QMKNames.name(0x01) == "_______")
        #expect(QMKNames.code("KC_ENTER") == 0x28 && QMKNames.code("KC_ENT") == 0x28 && QMKNames.code("KC_TRNS") == 0x01)
        #expect(QMKNames.code("QK_BOOT") == 0x7C00 && QMKNames.code("QK_KB_0") == 0x7E00)
    }

    @Test func everyCatalogueKeyExportsByName() {
        for k in Keycode.catalogue(layerCount: 16).flatMap(\.keycodes) {
            let e = QMKNames.expression(k.code)
            #expect(e != nil && !e!.hasPrefix("0x"), "\(k.name) exported as \(e ?? "nil")")
        }
    }

    @Test(arguments: [
        (UInt16(0x2104), "MT(MOD_LCTL, KC_A)"), (0x4129, "LT(1, KC_ESC)"), (0x0806, "LGUI(KC_C)"),
        (0x0306, "LCTL(LSFT(KC_C))"), (0x0F00, "KC_HYPR"), (0x0F04, "HYPR(KC_A)"), (0x1104, "RCTL(KC_A)"),
        (0x5221, "MO(1)"), (0x5202, "TO(2)"), (0x5263, "TG(3)"), (0x5281, "OSL(1)"), (0x52A2, "OSM(MOD_LSFT)"),
        (0x2F04, "MT(MOD_HYPR, KC_A)"), (0x3239, "MT(MOD_RSFT, KC_CAPS)"),
    ])
    func compositeRoundTrip(code: UInt16, text: String) throws {
        #expect(QMKNames.expression(code) == text)
        let file = try QMKKeymap.parse("const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [0] = { { \(text) } } };")
        #expect(file.layers[0].rows[0][0].code == code)
    }

    @Test func olderKeycodesAreNotExportedAsWrongKeys() {
        #expect(QMKNames.expression(0x2104, protocolVersion: 11) == nil)
        #expect(QMKNames.expression(0x0806, protocolVersion: 11) == "LGUI(KC_C)")   // numbered the same in old QMK
        let c = QMKKeymap.exportC(keymap: [[0x04, 0x6104]], rows: 1, cols: 2, keyboardName: "Old", vendorID: 1, productID: 2, protocolVersion: 9)
        #expect(c.contains("XXXXXXX /* 0x6104 */") && c.contains("1 key(s) use older VIA keycodes"))
    }

    @Test func exportParsesBackToTheSameKeymap() throws {
        let keymap: [[UInt16]] = [[0x29, 0x1E, 0x2104, 0x00, 0x5221, 0x01], [0x01, 0x3A, 0x4129, 0x0806, 0x52A2, 0x7E00]]
        let c = QMKKeymap.exportC(keymap: keymap, rows: 2, cols: 3, keyboardName: "Test", vendorID: 0x1234, productID: 0x5678, protocolVersion: 12)
        let file = try QMKKeymap.parse(c)
        #expect(file.layers.map(\.index) == [0, 1])
        #expect(file.layers.map { $0.rows.flatMap { $0.map(\.code) } } == keymap.map { $0.map(Optional.some) })
    }

    @Test func readsATypicalHandWrittenKeymap() throws {
        let src = """
        #include QMK_KEYBOARD_H
        enum layers { _BASE, _FN, _NAV = 5 };
        enum custom_keycodes { MY_MACRO = SAFE_RANGE, OTHER };
        #define HOME_A LGUI_T(KC_A)
        #define FN_ESC LT(_FN, KC_ESC)
        /* a comment with { unbalanced brackets ( */
        const uint16_t PROGMEM keymaps[][MATRIX_ROWS][MATRIX_COLS] = {
            [_BASE] = LAYOUT_ortho_1x4(HOME_A, FN_ESC, C(KC_C), MY_MACRO), // trailing comment )
            [_NAV] = LAYOUT_ortho_1x4(_______, XXXXXXX, KC_ENTER, MO(_FN)),
        };
        bool process_record_user(uint16_t keycode, keyrecord_t *record) {
            if (keycode == MY_MACRO && record->event.pressed) { SEND_STRING("hello"); }
            return true;
        }
        """
        let file = try QMKKeymap.parse(src)
        #expect(file.layers.map(\.index) == [0, 5] && file.layers[0].name == "_BASE" && file.layers[0].macro == "LAYOUT_ortho_1x4")
        #expect(file.layers[0].rows[0].map(\.code) == [0x2804, 0x4129, 0x0106, nil])
        #expect(file.layers[0].rows[0][3].text == "MY_MACRO")
        #expect(file.layers[1].rows[0].map(\.code) == [0x01, 0x00, 0x28, 0x5221])
        #expect(file.customCode.contains("process_record_user") && !file.customCode.contains("LAYOUT_ortho_1x4"))

        let order = [(row: 0, col: 3), (row: 0, col: 2), (row: 0, col: 1), (row: 0, col: 0)]
        let placed = try #require(QMKKeymap.placement(of: file.layers[0], rows: 1, cols: 4, keyOrder: order))
        #expect(placed.isAssumed && placed.keys[3]?.code == 0x2804)
        #expect(QMKKeymap.placement(of: file.layers[0], rows: 1, cols: 4, keyOrder: Array(order.prefix(3))) == nil)
    }

    @Test(arguments: [
        "nothing here",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [0] = LAYOUT(KC_A, KC_B };",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [0] = LAYOUT(KC_A",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [99] = LAYOUT(KC_A) };",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [UNKNOWN] = LAYOUT(KC_A) };",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [0] = LAYOUT(KC_A), [0] = LAYOUT(KC_B) };",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { [0] = 42 };",
        "keymaps[][MATRIX_ROWS][MATRIX_COLS] = { };",
    ])
    func malformedFilesThrow(_ src: String) {
        #expect(throws: QMKKeymap.ParseError.self) { try QMKKeymap.parse(src) }
    }

    @Test func oversizedFileIsRefused() {
        #expect(throws: QMKKeymap.ParseError.tooLarge) { try QMKKeymap.parse(String(repeating: "x", count: 600_000)) }
    }

    @Test func outOfRangeArgumentsAreUnknownNotWrapped() throws {
        let file = try QMKKeymap.parse("keymaps[][1][4] = { [0] = { { LT(16, KC_A), MO(40), MT(MOD_LCTL, LCTL(KC_A)), 0x1FFFF } } };")
        #expect(file.layers[0].rows[0].map(\.code) == [nil, nil, nil, nil])
    }
}

@Suite struct QMKBehavioursTests {
    @Test func recognisesTapDanceCombosAndTypedText() {
        let code = """
        tap_dance_action_t tap_dance_actions[] = { [TD_ESC_CAPS] = ACTION_TAP_DANCE_DOUBLE(KC_ESC, KC_CAPS) };
        const uint16_t PROGMEM jk_combo[] = {KC_J, KC_K, COMBO_END};
        combo_t key_combos[] = { COMBO(jk_combo, KC_ESC) };
        bool process_record_user(uint16_t keycode, keyrecord_t *record) {
            switch (keycode) {
                case EMAIL: if (record->event.pressed) { SEND_STRING("hello@example.com"); } return false;
                case OTHER: return true;
            }
            return true;
        }
        """
        #expect(QMKKeymap.behaviours(in: code) == [
            "The TD_ESC_CAPS key: tap once for Escape, tap twice quickly for Caps Lock.",
            "Pressing J and K together sends Escape.",
            "The EMAIL key types “hello@example.com”.",
        ])
    }
}
