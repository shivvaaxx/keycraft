import Foundation
import Testing
@testable import KeycraftCore

@Suite struct VIADefinitionTests {
    private func key(_ def: VIADefinition, _ row: Int, _ col: Int) -> PhysicalKey? {
        def.keys.first { $0.row == row && $0.col == col }
    }

    @Test(arguments: [(0, 2), (-1, 2), (2, -5), (256, 2), (2, 1000)])
    func rejectsMatrixOutsideByteRange(rows: Int, cols: Int) {
        let json = #"{"name":"Bad","vendorId":"0x1234","productId":"0x5678","matrix":{"rows":\#(rows),"cols":\#(cols)},"layouts":{"keymap":[["0,0"]]}}"#
        #expect(throws: DecodingError.self) { try VIADefinition(data: Data(json.utf8)) }
    }

    @Test func gh60() throws {
        let def = try VIADefinition(data: fixture("v3_gh60_satan_satan.json"))
        #expect(def.name == "GH60 Satan")
        #expect(def.vendorID == 0x4335 && def.productID == 0x0002)
        #expect(def.rows == 5 && def.cols == 14)
        #expect(def.optionTitles.first == "Split Backspace" && def.optionTitles.count == 5)
        #expect(def.keys.count == 61)   // of 86 labelled keys, the rest belong to non-default layout options
        // Raw KLE coordinates: every visible key sits right of the 2.5u the hidden options occupy.
        #expect(key(def, 0, 0) == PhysicalKey(row: 0, col: 0, x: 2.5, y: 0, w: 1, h: 1))
        #expect(key(def, 0, 13) == PhysicalKey(row: 0, col: 13, x: 15.5, y: 0, w: 2, h: 1))
        #expect(key(def, 1, 1) == PhysicalKey(row: 1, col: 1, x: 4.0, y: 1, w: 1, h: 1))
        #expect(key(def, 4, 5) == PhysicalKey(row: 4, col: 5, x: 6.25, y: 4, w: 6.25, h: 1))
        // ISO enter option (group 1, option 1) and split shifts are hidden by default.
        #expect(key(def, 2, 12) == nil)
        #expect(key(def, 3, 1) == nil)
        #expect(key(def, 3, 12) == nil)
        #expect(key(def, 2, 13)?.w == 2.25)
    }

    @Test func keychronQ1() throws {
        let def = try VIADefinition(data: fixture("v3_keychron_q1_v2_ansi.json"))
        #expect(def.name == "Keychron Q1V2 ANSI")
        #expect(def.vendorID == 0x3434 && def.productID == 0x0106)
        #expect(def.rows == 6 && def.cols == 16)
        #expect(def.keys.count == 82)
        #expect(key(def, 0, 0) == PhysicalKey(row: 0, col: 0, x: 0, y: 0, w: 1, h: 1))
        #expect(key(def, 0, 1)?.x == 1.25)
        #expect(key(def, 5, 15) == PhysicalKey(row: 5, col: 15, x: 15.25, y: 5.5, w: 1, h: 1))
    }

    @Test func rotationAndOutOfRangeLabelsDoNotCrash() throws {
        let json = """
        {"name":"T","vendorId":"0x0001","productId":"0x0002","matrix":{"rows":2,"cols":2},
         "layouts":{"keymap":[[{"r":15,"rx":2,"ry":1,"c":"#fff","a":4,"x2":1,"w2":2},"0,0",{"w":2},"\\n\\n\\n9,9","0,1"],
                              [{"y":0.5},"1,0","7,7"]]}}
        """
        let def = try VIADefinition(data: Data(json.utf8))
        #expect(def.keys.map { [$0.row, $0.col] } == [[0, 0], [0, 1], [1, 0]])
        #expect(def.keys[0].angle == 15 && def.keys[0].x == 2 && def.keys[0].y == 1)   // cursor starts at (rx, ry)
        #expect(def.keys[1].x == 5)          // 0,0 (w1) + decal (w2) both advanced the cursor
        #expect((def.keys[2].x, def.keys[2].y) == (2, 2.5))   // next row: x back to rx, y + 1 + {"y": 0.5}
        #expect(def.optionTitles.isEmpty)    // labels are optional
    }

    @Test func badHexIsRejected() {
        let json = #"{"name":"T","vendorId":"zz","productId":"0x2","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[]}}"#
        #expect(throws: DecodingError.self) { try VIADefinition(data: Data(json.utf8)) }
    }

    @Test func rotationClusterFollowsKLE() throws {
        // {r,rx,ry} moves the cursor to (rx, ry); a new row returns x to rx, not 0.
        let json = """
        {"name":"R","vendorId":"0x1","productId":"0x2","matrix":{"rows":2,"cols":2},
         "layouts":{"keymap":[["0,0"],[{"r":90,"rx":1,"ry":1,"x":1},"0,1","1,0"],["1,1"]]}}
        """
        let def = try VIADefinition(data: Data(json.utf8))
        #expect(def.keys.count == 4)
        #expect(def.keys[0].angle == 0 && def.keys[0].center == CGPoint(x: 0.5, y: 0.5))
        let k = def.keys[1]          // rect (2,1,1,1) rotated 90 degrees about (1,1): centre (2.5,1.5) -> (0.5,2.5)
        #expect(k.angle == 90 && (k.originX, k.originY) == (1, 1) && (k.x, k.y) == (2, 1))
        #expect(abs(k.center.x - 0.5) < 1e-9 && abs(k.center.y - 2.5) < 1e-9)
        #expect((def.keys[2].x, def.keys[2].y) == (3, 1))
        #expect((def.keys[3].x, def.keys[3].y) == (1, 2))     // next row: x = rx, y + 1
        let b = def.bounds
        #expect(b.minX < 0.5 && b.minY == 0 && b.width > 0)    // rotated corners reach left of the cluster origin
        let corners = k.corners
        #expect(abs(corners[0].x - 1) < 1e-9 && abs(corners[0].y - 2) < 1e-9)   // (2,1) -> (1,2)
    }

    @Test func decalsAreSkippedButAdvanceTheCursor() throws {
        let json = """
        {"name":"D","vendorId":"0x1","productId":"0x2","matrix":{"rows":1,"cols":2},
         "layouts":{"keymap":[[{"d":true,"w":2},"0,0",{"x":0.5},"0,1"]]}}
        """
        let def = try VIADefinition(data: Data(json.utf8))
        #expect(def.keys.map { [$0.row, $0.col] } == [[0, 1]] && def.keys[0].x == 2.5)
    }

    @Test func matrixPositionsTolerateWhitespace() throws {
        let json = #"{"name":"W","vendorId":" 0X0A ","productId":"b","matrix":{"rows":1,"cols":2},"layouts":{"keymap":[["0, 1","\n\n\n 0 , 0"]]}}"#
        let def = try VIADefinition(data: Data(json.utf8))
        #expect(def.keys.count == 1 && def.keys[0].col == 1 && (def.vendorID, def.productID) == (10, 11))
    }

    @Test func customKeycodesAreDecoded() throws {
        let json = """
        {"name":"C","vendorId":"0x1","productId":"0x2","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[["0,0"]]},
         "customKeycodes":[{"name":"Mission Control","title":"Open Mission Control","shortName":"Mis Ctrl"},{"title":"Only Title"}]}
        """
        let def = try VIADefinition(data: Data(json.utf8))
        #expect(def.customKeycodes == [CustomKeycode(name: "Mission Control", title: "Open Mission Control", shortName: "Mis Ctrl"),
                                       CustomKeycode(name: "Only Title", title: "Only Title", shortName: "")])
    }

    @Test func importFileValidatesThenCopies() throws {
        let userDir = makeTempDirectory(), custom = makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: userDir); try? FileManager.default.removeItem(at: custom) }
        let file = custom.appending(path: "mine.json")
        try Data(#"{"name":"Mine","vendorId":"0x1234","productId":"0x5678","matrix":{"rows":1,"cols":1},"layouts":{"keymap":[["0,0"]]}}"#.utf8).write(to: file)
        #expect(try VIADefinition.importFile(file, userDirectory: userDir).keys.count == 1)
        #expect(FileManager.default.fileExists(atPath: userDir.appending(path: "1234-5678.json").path))
        try Data("not json".utf8).write(to: file)
        #expect(throws: (any Error).self) { try VIADefinition.importFile(file, userDirectory: userDir) }
    }
}
