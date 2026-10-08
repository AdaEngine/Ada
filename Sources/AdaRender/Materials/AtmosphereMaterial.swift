//
//  AtmosphereMaterial.swift
//  AdaEngine
//

import AdaAssets
import Math

/// A lightweight Fresnel atmosphere rendered on a sphere surrounding a planet.
public final class AtmosphereMaterial: PBRMaterial, @unchecked Sendable {
    /// Controls how tightly the haze follows the planet silhouette.
    public var fresnelPower: Float = 4.5

    /// Multiplies the opacity produced by the atmosphere shader.
    public var atmosphereIntensity: Float = 1

    override public init() {
        super.init()
        baseColorFactor = [0.42, 0.78, 1, 0.42]
        metallicFactor = 0
        roughnessFactor = 1
    }

    public required init(from assetDecoder: AssetDecoder) throws {
        try super.init(from: assetDecoder)
    }
}
