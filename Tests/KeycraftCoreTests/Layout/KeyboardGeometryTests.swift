import CoreGraphics
import Testing
@testable import KeycraftCore

struct KeyboardGeometryTests {
    /// Two rows of three 1u keys.
    private static let grid = KeyboardGeometry(keys: (0..<6).map {
        PhysicalKey(row: $0 / 3, col: $0 % 3, x: Double($0 % 3), y: Double($0 / 3), w: 1, h: 1)
    })

    @Test func unitFitsWidthAndClamps() {
        // 3u x 2u: width-limited at 100pt/u, so capped at 64
        #expect(Self.grid.unit(fitting: CGSize(width: 300, height: 1000)) == 64)
        // 150pt / 3u = 50
        #expect(Self.grid.unit(fitting: CGSize(width: 150, height: 1000)) == 50)
        // height-limited: 80pt / 2u = 40
        #expect(Self.grid.unit(fitting: CGSize(width: 1000, height: 80)) == 40)
        // below the floor the caps stop shrinking
        #expect(Self.grid.unit(fitting: CGSize(width: 30, height: 30)) == 30)
    }

    @Test func boundsIncludeRotation() {
        // A 2u x 1u key rotated 90 degrees clockwise about its own top-left corner occupies x in [-1, 0], y in [0, 2].
        let g = KeyboardGeometry(keys: [PhysicalKey(row: 0, col: 0, x: 0, y: 0, w: 2, h: 1, angle: 90, originX: 0, originY: 0)])
        #expect(abs(g.bounds.width - 1) < 1e-9 && abs(g.bounds.height - 2) < 1e-9)
        #expect(abs(g.bounds.minX + 1) < 1e-9 && abs(g.bounds.minY) < 1e-9)
        // centres are relative to the bounds origin: centre of the rotated key is (-0.5, 1) -> (0.5, 1)
        #expect(abs(g.centers[0].x - 0.5) < 1e-9 && abs(g.centers[0].y - 1) < 1e-9)
    }

    @Test func arrowNeighboursOnGrid() {
        let g = Self.grid
        #expect(g.neighbour(of: 0, .right) == 1 && g.neighbour(of: 0, .down) == 3)
        #expect(g.neighbour(of: 4, .up) == 1 && g.neighbour(of: 4, .left) == 3)
        #expect(g.neighbour(of: 0, .left) == nil && g.neighbour(of: 0, .up) == nil)
        #expect(g.neighbour(of: 5, .right) == nil && g.neighbour(of: 5, .down) == nil)
    }

    @Test func staggeredRowsPickTheClosestCapAbove() {
        // Row 0: keys at x 0, 1, 2. Row 1: a 6u space bar centred under the middle key.
        let g = KeyboardGeometry(keys: [
            PhysicalKey(row: 0, col: 0, x: 0, y: 0, w: 1, h: 1), PhysicalKey(row: 0, col: 1, x: 1, y: 0, w: 1, h: 1),
            PhysicalKey(row: 0, col: 2, x: 2, y: 0, w: 1, h: 1), PhysicalKey(row: 1, col: 0, x: -1.5, y: 1, w: 6, h: 1),
        ])
        #expect(g.neighbour(of: 3, .up) == 1)
        #expect(g.neighbour(of: 0, .down) == 3)
    }

    @Test func unreachableByConeStillReachableByFallback() {
        // Key 1 is far to the right and slightly below: nothing is in the 45 degree cone going down from key 0.
        let g = KeyboardGeometry(keys: [PhysicalKey(row: 0, col: 0, x: 0, y: 0, w: 1, h: 1),
                                        PhysicalKey(row: 0, col: 1, x: 5, y: 1, w: 1, h: 1)])
        #expect(g.neighbour(of: 0, .down) == 1)
    }
}
