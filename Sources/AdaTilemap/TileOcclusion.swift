import Math

/// Per-cell occlusion. A missing override inherits the atlas tile's shape.
public struct TileOcclusionOverride: Codable, Equatable, Sendable {
    public enum Mode: String, Codable, Sendable { case disabled, polygon }
    public let mode: Mode
    public let points: [Vector2]?
    /// Authored cell size. Missing sizes preserve legacy local-space coordinates.
    public let referenceSize: Size?

    public static let disabled = Self(mode: .disabled, points: nil, referenceSize: nil)

    /// Points are centered, with positive Y up. Rotation and reflection follow the cell.
    public static func polygon(_ points: [Vector2], referenceSize: Size? = nil) throws -> Self {
        try TileOcclusionPolygon.validate(points, referenceSize: referenceSize)
        return Self(mode: .polygon, points: points, referenceSize: referenceSize)
    }

    private init(mode: Mode, points: [Vector2]?, referenceSize: Size?) {
        self.mode = mode
        self.points = points
        self.referenceSize = referenceSize
    }

    private enum CodingKeys: String, CodingKey { case mode, points, referenceSize }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let mode = try container.decode(Mode.self, forKey: .mode)
        if mode == .disabled {
            self = .disabled
            return
        }
        self = try .polygon(
            container.decode([Vector2].self, forKey: .points),
            referenceSize: container.decodeIfPresent(Size.self, forKey: .referenceSize)
        )
    }
}

/// Portable cell overrides used by palette-based tile map resources.
public struct TileMapCellOcclusion: Codable, Equatable, Sendable {
    public let position: PointInt
    public let occlusion: TileOcclusionOverride

    public init(position: PointInt, occlusion: TileOcclusionOverride) {
        self.position = position
        self.occlusion = occlusion
    }
}

/// Validation shared by runtime APIs and visual polygon authoring.
public enum TileOcclusionPolygon {
    public enum ValidationError: Error { case invalidSize, invalidPolygon }

    /// Accepts simple, nondegenerate rings in either winding, without a repeated closing point.
    public static func validate(_ points: [Vector2], referenceSize: Size? = nil) throws {
        if let size = referenceSize, !size.width.isFinite || !size.height.isFinite || size.width <= 0 || size.height <= 0 {
            throw ValidationError.invalidSize
        }
        guard (3...256).contains(points.count), points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            throw ValidationError.invalidPolygon
        }
        func cross(_ a: Vector2, _ b: Vector2) -> Double { Double(a.x) * Double(b.y) - Double(a.y) * Double(b.x) }
        func touches(_ a: Vector2, _ b: Vector2, _ c: Vector2, _ d: Vector2) -> Bool {
            let ab = b - a, cd = d - c
            let ac = cross(ab, c - a), ad = cross(ab, d - a)
            let ca = cross(cd, a - c), cb = cross(cd, b - c)
            guard min(a.x, b.x) <= max(c.x, d.x), min(c.x, d.x) <= max(a.x, b.x),
                  min(a.y, b.y) <= max(c.y, d.y), min(c.y, d.y) <= max(a.y, b.y) else { return false }
            return ac * ad <= 0 && ca * cb <= 0
        }
        var area: Double = 0
        for i in points.indices {
            let next = (i + 1) % points.count
            guard points[i] != points[next] else { throw ValidationError.invalidPolygon }
            area += cross(points[i] - points[0], points[next] - points[0])
            for j in (i + 1)..<points.count {
                let end = (j + 1) % points.count
                if next == j || end == i { continue }
                if touches(points[i], points[next], points[j], points[end]) { throw ValidationError.invalidPolygon }
            }
        }
        guard area.isFinite, abs(area) > 1e-10 else { throw ValidationError.invalidPolygon }
    }
}
