import Foundation
import Math

public enum TerrainSurfaceBrushOperation: String, Codable, CaseIterable, Sendable {
    case paintLayer, eraseLayer, paintMask, paintTint, eraseTint, paintRoughness, eraseRoughness
}

/// Terrain-local surface controls. Strength is coverage per distance-spaced dab; zero mask value erases a rule mask.
public struct TerrainSurfaceBrushSettings: Codable, Equatable, Sendable {
    public var operation: TerrainSurfaceBrushOperation
    public var radius: Float
    public var strength: Float
    public var layerID: UInt16 = 0
    public var maskID: UInt16 = 0
    public var maskValue: Float = 1
    public var tint: Vector4 = .one
    public var roughness: Float = 1
    public var shape: TerrainBrushShape = .softRound
    public var falloff: Float = 1
    public var spacing: Float = 0.25
    public var rotation: Float = 0
    public var rotationJitter: Float = 0
    public var seed: UInt64 = 0
    public var heightRange: ClosedRange<Float>?
    public var slopeRange: ClosedRange<Float>?

    public init(operation: TerrainSurfaceBrushOperation, radius: Float = 8, strength: Float = 1) {
        self.operation = operation; self.radius = radius; self.strength = strength
    }
}

/// One bounded surface gesture, evaluated on a private snapshot and committed with compact Undo data.
public struct TerrainSurfaceBrushStroke: Codable, Equatable, Sendable {
    public let settings: TerrainSurfaceBrushSettings
    public let points: [TerrainBrushPoint]

    public init(settings: TerrainSurfaceBrushSettings, points: [TerrainBrushPoint]) {
        self.settings = settings; self.points = points
    }

    /// Shares distance spacing, alpha validation, rotation and bounded footprint planning with sculpt tools.
    func samplingStroke() throws -> TerrainHeightBrushStroke {
        let s = settings
        guard s.strength.isFinite, (0...1).contains(s.strength), s.maskValue.isFinite, (0...1).contains(s.maskValue),
            s.roughness.isFinite, (0...1).contains(s.roughness),
            s.tint.x.isFinite, s.tint.y.isFinite, s.tint.z.isFinite, s.tint.w.isFinite,
            (0...1).contains(s.tint.x), (0...1).contains(s.tint.y), (0...1).contains(s.tint.z), (0...1).contains(s.tint.w)
        else { throw TerrainSurfaceEditError.invalidValue }
        var mask = TerrainHeightBrushSettings(operation: .noise, radius: s.radius, strength: s.strength)
        mask.shape = s.shape; mask.falloff = s.falloff; mask.spacing = s.spacing
        mask.rotation = s.rotation; mask.rotationJitter = s.rotationJitter; mask.seed = s.seed
        mask.heightRange = s.heightRange; mask.slopeRange = s.slopeRange
        let stroke = TerrainHeightBrushStroke(settings: mask, points: points)
        try stroke.validate()
        return stroke
    }
}
