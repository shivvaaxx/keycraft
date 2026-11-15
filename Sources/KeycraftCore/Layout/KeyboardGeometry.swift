import CoreGraphics
import Foundation

/// Where every cap sits on screen: bounds after rotation, fit-to-window scale, and arrow-key neighbours.
/// All coordinates are key units (1u = one standard key) unless a method says points.
public struct KeyboardGeometry: Sendable {
    public enum Direction: Sendable { case up, down, left, right }

    public static let minUnit = 30.0
    public static let maxUnit = 64.0

    public let keys: [PhysicalKey]
    /// Bounding box of all rotated key corners.
    public let bounds: CGRect
    /// Cap centres relative to `bounds.origin`.
    public let centers: [CGPoint]

    public init(keys: [PhysicalKey]) {
        self.keys = keys
        let points = keys.flatMap(\.corners)
        let rect: CGRect
        if let minX = points.map(\.x).min(), let maxX = points.map(\.x).max(),
           let minY = points.map(\.y).min(), let maxY = points.map(\.y).max() {
            rect = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        } else {
            rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        bounds = rect
        centers = keys.map { CGPoint(x: $0.center.x - rect.minX, y: $0.center.y - rect.minY) }
    }

    /// Points per key unit: as large as fits `available`, never above `maxUnit`, never below `minUnit`
    /// (below the floor the canvas scrolls instead of shrinking the caps further).
    public func unit(fitting available: CGSize) -> Double {
        let fit = min(available.width / bounds.width, available.height / bounds.height)
        guard fit.isFinite else { return Self.minUnit }
        return min(max(fit, Self.minUnit), Self.maxUnit)
    }

    /// The nearest cap in `direction`, preferring caps inside a 45 degree cone; falls back to any cap that
    /// lies that way so every cap stays reachable. nil at the edge of the keyboard.
    public func neighbour(of index: Int, _ direction: Direction) -> Int? {
        guard centers.indices.contains(index) else { return nil }
        let origin = centers[index]
        var inCone: (index: Int, score: Double)?
        var anywhere: (index: Int, score: Double)?
        for (j, p) in centers.enumerated() where j != index {
            let (dx, dy) = (p.x - origin.x, p.y - origin.y)
            let (along, across): (Double, Double) = switch direction {
            case .right: (dx, abs(dy))
            case .left: (-dx, abs(dy))
            case .down: (dy, abs(dx))
            case .up: (-dy, abs(dx))
            }
            guard along > 0.1 else { continue }
            let score = along + 2 * across
            if anywhere == nil || score < anywhere!.score { anywhere = (j, score) }
            if across <= along, inCone == nil || score < inCone!.score { inCone = (j, score) }
        }
        return (inCone ?? anywhere)?.index
    }
}
