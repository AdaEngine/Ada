import Math

/// Address-independent artist-authored surface channels. Zero strengths reveal automatic shading.
public struct TerrainSurfacePaint: Equatable, Sendable {
    public let layerIDs: SIMD4<UInt16>
    public let weights: Vector4
    public let overrideStrength: Float
    public let tint: Vector4
    public let tintStrength: Float
    public let roughness: Float
    public let roughnessStrength: Float

    public init(
        layerIDs: SIMD4<UInt16> = .zero,
        weights: Vector4 = .zero,
        overrideStrength: Float = 0,
        tint: Vector4 = .one,
        tintStrength: Float = 0,
        roughness: Float = 1,
        roughnessStrength: Float = 0
    ) {
        self.layerIDs = layerIDs; self.weights = weights; self.overrideStrength = overrideStrength
        self.tint = tint; self.tintStrength = tintStrength; self.roughness = roughness; self.roughnessStrength = roughnessStrength
    }

    public var isEmpty: Bool { overrideStrength == 0 && tintStrength == 0 && roughnessStrength == 0 }

    /// Checks finite normalized channels. Empty values are valid and erase their canonical sample.
    public func validate() throws { try regionSample(x: 0, z: 0).validate(allowEmpty: true) }

    public func regionSample(x: UInt8, z: UInt8) -> TerrainRegionSurfaceSample {
        .init(
            x: x,
            z: z,
            layerIDs: layerIDs,
            weights: weights,
            overrideStrength: overrideStrength,
            tint: tint,
            tintStrength: tintStrength,
            roughness: roughness,
            roughnessStrength: roughnessStrength
        )
    }
}

extension TerrainRegionSurfaceSample {
    public var paint: TerrainSurfacePaint {
        .init(
            layerIDs: layerIDs,
            weights: weights,
            overrideStrength: overrideStrength,
            tint: tint,
            tintStrength: tintStrength,
            roughness: roughness,
            roughnessStrength: roughnessStrength
        )
    }
}
