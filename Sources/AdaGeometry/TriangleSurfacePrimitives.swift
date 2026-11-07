import Math

extension TriangleSurface {
    public static func box(minimum: Vector3, maximum: Vector3, source: UInt32 = 0) throws -> Self {
        guard minimum.x < maximum.x, minimum.y < maximum.y, minimum.z < maximum.z else { throw TriangleGeometryError.invalidInput }
        let positions: [Vector3] = [
            [minimum.x, minimum.y, minimum.z], [maximum.x, minimum.y, minimum.z], [maximum.x, maximum.y, minimum.z], [minimum.x, maximum.y, minimum.z],
            [minimum.x, minimum.y, maximum.z], [maximum.x, minimum.y, maximum.z], [maximum.x, maximum.y, maximum.z], [minimum.x, maximum.y, maximum.z]
        ]
        let indices: [UInt32] = [0, 2, 1, 0, 3, 2, 4, 5, 6, 4, 6, 7, 0, 1, 5, 0, 5, 4, 3, 7, 6, 3, 6, 2, 0, 4, 7, 0, 7, 3, 1, 2, 6, 1, 6, 5]
        let result = Self(positions: positions, indices: indices, faceSources: Array(repeating: source, count: 12), faceIDs: Array(0..<12))
        try result.validate()
        return result
    }

    public static func ground(size: Vector2, cells: Int = 16) throws -> Self {
        guard size.x.isFinite, size.y.isFinite, size.x > 0, size.y > 0, (1...128).contains(cells) else { throw TriangleGeometryError.invalidInput }
        var positions: [Vector3] = [], indices: [UInt32] = []
        for z in 0...cells {
            for x in 0...cells { positions.append([Float(x) / Float(cells) * size.x - size.x / 2, 0, Float(z) / Float(cells) * size.y - size.y / 2]) }
        }
        let width = UInt32(cells + 1)
        for z in 0..<cells {
            for x in 0..<cells {
                let a = UInt32(z * (cells + 1) + x)
                indices += [a, a + width, a + 1, a + 1, a + width, a + width + 1]
            }
        }
        return Self(positions: positions, indices: indices, normals: Array(repeating: .up, count: positions.count),
                    textureCoordinates: positions.map { [$0.x, $0.z] })
    }

    public var bounds: MeshTerrainBounds? {
        guard let first = positions.first else { return nil }
        var low = first, high = first
        for point in positions {
            low = [min(low.x, point.x), min(low.y, point.y), min(low.z, point.z)]
            high = [max(high.x, point.x), max(high.y, point.y), max(high.z, point.z)]
        }
        return .init(minimum: low, maximum: high)
    }
}

public struct MeshTerrainBounds: Codable, Equatable, Sendable {
    public var minimum: Vector3
    public var maximum: Vector3
    public init(minimum: Vector3, maximum: Vector3) { self.minimum = minimum; self.maximum = maximum }
    public func intersects(_ other: Self, horizontal: Bool = false) -> Bool {
        minimum.x <= other.maximum.x && maximum.x >= other.minimum.x && minimum.z <= other.maximum.z && maximum.z >= other.minimum.z
            && (horizontal || minimum.y <= other.maximum.y && maximum.y >= other.minimum.y)
    }
    public func contains(_ point: Vector3) -> Bool {
        point.x >= minimum.x && point.x <= maximum.x && point.y >= minimum.y && point.y <= maximum.y && point.z >= minimum.z && point.z <= maximum.z
    }
    public func expanded(by amount: Float) -> Self { .init(minimum: minimum - Vector3(amount), maximum: maximum + Vector3(amount)) }
    public func union(_ other: Self) -> Self {
        .init(minimum: [min(minimum.x, other.minimum.x), min(minimum.y, other.minimum.y), min(minimum.z, other.minimum.z)],
              maximum: [max(maximum.x, other.maximum.x), max(maximum.y, other.maximum.y), max(maximum.z, other.maximum.z)])
    }
}
