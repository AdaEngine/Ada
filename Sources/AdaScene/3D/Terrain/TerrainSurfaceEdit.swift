import AdaAssets

/// Replaces one canonical paint value. Nil or an empty validated value erases all of its surface overrides.
public struct TerrainSurfaceUpdate: Equatable, Sendable {
    public let point: TerrainGridPoint
    public let paint: TerrainSurfacePaint?

    public init(point: TerrainGridPoint, paint: TerrainSurfacePaint?) { self.point = point; self.paint = paint }
}

/// Replaces one automatic-rule mask. A value of zero removes its sparse record.
public struct TerrainRuleMaskUpdate: Equatable, Sendable {
    public let point: TerrainGridPoint
    public let maskID: UInt16
    public let value: Float

    public init(point: TerrainGridPoint, maskID: UInt16, value: Float) { self.point = point; self.maskID = maskID; self.value = value }
}

/// One compact committed paint delta, retaining the previous authored channels for Undo.
public struct TerrainSurfaceChange: Equatable, Sendable {
    public let point: TerrainGridPoint
    public let previous: TerrainSurfacePaint?
    public let paint: TerrainSurfacePaint?

    public var reversedUpdate: TerrainSurfaceUpdate { .init(point: point, paint: previous) }
}

/// One compact committed rule-mask delta.
public struct TerrainRuleMaskChange: Equatable, Sendable {
    public let point: TerrainGridPoint
    public let maskID: UInt16
    public let previousValue: Float
    public let value: Float

    public var reversedUpdate: TerrainRuleMaskUpdate { .init(point: point, maskID: maskID, value: previousValue) }
}
