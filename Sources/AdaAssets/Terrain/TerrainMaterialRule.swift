import Foundation

/// Terrain-local range, with a smooth transition outside its fully weighted interval.
public struct TerrainMaterialRange: Codable, Equatable, Sendable {
    public let minimum: Float
    public let maximum: Float
    public let transition: Float

    public init(minimum: Float, maximum: Float, transition: Float = 0) {
        self.minimum = minimum; self.maximum = maximum; self.transition = transition
    }

    private enum CodingKeys: CodingKey { case minimum, maximum, transition }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            minimum: try container.decode(Float.self, forKey: .minimum),
            maximum: try container.decode(Float.self, forKey: .maximum),
            transition: try container.decodeIfPresent(Float.self, forKey: .transition) ?? 0
        )
    }

    func validate() throws {
        guard minimum.isFinite, maximum.isFinite, minimum <= maximum, transition.isFinite, transition >= 0 else {
            throw TerrainManifestError.malformed("invalid terrain material range")
        }
    }
}

/// A saved automatic contribution. Height/curvature use terrain-local units, slope uses degrees.
public struct TerrainMaterialRule: Codable, Equatable, Sendable {
    public let layerID: UInt16
    public let enabled: Bool
    public let weight: Float
    public let height: TerrainMaterialRange?
    public let slope: TerrainMaterialRange?
    public let curvature: TerrainMaterialRange?
    public let seed: UInt64
    public let noiseFrequency: Float
    public let noiseStrength: Float
    public let maskID: UInt16?

    public init(
        layerID: UInt16,
        enabled: Bool = true,
        weight: Float = 1,
        height: TerrainMaterialRange? = nil,
        slope: TerrainMaterialRange? = nil,
        curvature: TerrainMaterialRange? = nil,
        seed: UInt64 = 0,
        noiseFrequency: Float = 0.05,
        noiseStrength: Float = 0,
        maskID: UInt16? = nil
    ) {
        self.layerID = layerID; self.enabled = enabled; self.weight = weight; self.height = height; self.slope = slope
        self.curvature = curvature; self.seed = seed; self.noiseFrequency = noiseFrequency; self.noiseStrength = noiseStrength; self.maskID = maskID
    }

    private enum CodingKeys: CodingKey { case layerID, enabled, weight, height, slope, curvature, seed, noiseFrequency, noiseStrength, maskID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            layerID: try container.decode(UInt16.self, forKey: .layerID),
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true,
            weight: try container.decodeIfPresent(Float.self, forKey: .weight) ?? 1,
            height: try container.decodeIfPresent(TerrainMaterialRange.self, forKey: .height),
            slope: try container.decodeIfPresent(TerrainMaterialRange.self, forKey: .slope),
            curvature: try container.decodeIfPresent(TerrainMaterialRange.self, forKey: .curvature),
            seed: try container.decodeIfPresent(UInt64.self, forKey: .seed) ?? 0,
            noiseFrequency: try container.decodeIfPresent(Float.self, forKey: .noiseFrequency) ?? 0.05,
            noiseStrength: try container.decodeIfPresent(Float.self, forKey: .noiseStrength) ?? 0,
            maskID: try container.decodeIfPresent(UInt16.self, forKey: .maskID)
        )
    }

    func validate() throws {
        guard weight.isFinite, weight >= 0, weight <= 1_000_000, noiseFrequency.isFinite, noiseFrequency > 0,
            noiseStrength.isFinite, (0...1).contains(noiseStrength)
        else {
            throw TerrainManifestError.malformed("invalid terrain material rule")
        }
        try height?.validate(); try slope?.validate(); try curvature?.validate()
        if let slope, slope.minimum < 0 || slope.maximum > 90 { throw TerrainManifestError.malformed("terrain material slope must be in 0...90 degrees") }
    }
}
