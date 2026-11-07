import Foundation
import Math

public enum TerrainInstanceBrushOperation: String, Codable, Equatable, Sendable {
    case paint, erase
}

/// Terrain-local paint controls; density is candidates per square unit and distance is an exclusion radius.
public struct TerrainInstanceBrushSettings: Codable, Equatable, Sendable {
    public var operation: TerrainInstanceBrushOperation
    public var prototypeID: UInt16
    public var radius: Float
    public var density: Float
    public var minimumDistance: Float = 1
    public var strength: Float = 1
    public var shape: TerrainBrushShape = .softRound
    public var falloff: Float = 1
    public var spacing: Float = 0.25
    public var rotation: Float = 0
    public var rotationJitter: Float = 0
    public var seed: UInt64 = 0
    public var scaleRange: ClosedRange<Float> = 0.8...1.2
    public var yawRange: ClosedRange<Float> = 0...(2 * .pi)
    public var heightOffset: Float = 0
    public var alignToNormal: Bool = true
    public var tint: Vector4 = .one
    public var heightRange: ClosedRange<Float>?
    public var slopeRange: ClosedRange<Float>?
    /// Optional stable layer ID whose resolved surface weight must meet minimumMaterialWeight.
    public var materialLayerID: UInt16?
    public var minimumMaterialWeight: Float = 0.5
    public var eraseAllPrototypes: Bool = false
    /// Requests nearby static collision for new placements. Decorative painting defaults to false.
    public var requestsCollision: Bool = false

    public init(prototypeID: UInt16, operation: TerrainInstanceBrushOperation = .paint, radius: Float = 8, density: Float = 1) {
        self.prototypeID = prototypeID; self.operation = operation; self.radius = radius; self.density = density
    }
}

/// A deterministic paint/erase gesture. Authored placements persist; they are not regenerated per frame.
public struct TerrainInstanceBrushStroke: Codable, Equatable, Sendable {
    public let settings: TerrainInstanceBrushSettings
    public let points: [TerrainBrushPoint]

    public init(settings: TerrainInstanceBrushSettings, points: [TerrainBrushPoint]) {
        self.settings = settings; self.points = points
    }
}

public enum TerrainInstanceBrushError: LocalizedError {
    case invalidParameters, invalidCoordinates, workBudgetExceeded, missingPrototype, missingMaterialLayer

    public var errorDescription: String? {
        switch self {
        case .invalidParameters: "Mesh brush requires finite bounded density, spacing, variation and filter settings"
        case .invalidCoordinates: "Mesh brush coordinates exceed its supported sampling precision"
        case .workBudgetExceeded: "Mesh brush exceeds its bounded candidate/sample visit budget"
        case .missingPrototype: "Mesh brush requires a registered static model prototype"
        case .missingMaterialLayer: "Mesh brush material layer is missing from the terrain palette"
        }
    }
}

extension TerrainInstanceBrushStroke {
    func validate() throws {
        let s = settings
        guard s.radius.isFinite, s.radius > 0, s.density.isFinite, (0...10_000).contains(s.density),
            s.minimumDistance.isFinite, (0.05...10_000).contains(s.minimumDistance), s.strength.isFinite, (0...1).contains(s.strength),
            s.scaleRange.lowerBound.isFinite, s.scaleRange.upperBound.isFinite, s.scaleRange.lowerBound >= 0.0001, s.scaleRange.upperBound <= 10_000,
            s.yawRange.lowerBound.isFinite, s.yawRange.upperBound.isFinite, s.heightOffset.isFinite,
            s.minimumMaterialWeight.isFinite, (0...1).contains(s.minimumMaterialWeight),
            (0...1).contains(s.tint.x), (0...1).contains(s.tint.y), (0...1).contains(s.tint.z), (0...1).contains(s.tint.w)
        else { throw TerrainInstanceBrushError.invalidParameters }
        for range in [s.heightRange, s.slopeRange].compactMap({ $0 }) {
            guard range.lowerBound.isFinite, range.upperBound.isFinite else { throw TerrainInstanceBrushError.invalidParameters }
        }
        if let range = s.slopeRange, range.lowerBound < 0 || range.upperBound > 90 { throw TerrainInstanceBrushError.invalidParameters }
        // The shared sampler validates shape/alpha/rotation/input data before any source loading.
    }
}
