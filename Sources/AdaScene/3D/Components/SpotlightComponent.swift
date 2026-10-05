//
//  SpotlightComponent.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/21/22.
//

import AdaECS
import Math

/// A local light whose +Z axis points down the cone. Angles are half-angles in degrees.
@Component
public struct SpotLightComponent: Codable, Sendable {
    public var radiance: Vector3
    /// Linear radiance multiplier at one meter, before range/cone attenuation.
    public var intensity: Float
    public var castShadows: Bool
    public var range: Float = 10
    public var innerConeAngle: Float = 20
    public var outerConeAngle: Float = 35
    public var shadowBias: Float = 0.002
    public var shadowSlopeBias: Float = 0.004
    public var shadowPriority: Int = 0

    public init(
        radiance: Vector3 = .one,
        intensity: Float = 1,
        castShadows: Bool = true,
        range: Float = 10,
        innerConeAngle: Float = 20,
        outerConeAngle: Float = 35,
        shadowBias: Float = 0.002,
        shadowSlopeBias: Float = 0.004,
        shadowPriority: Int = 0
    ) {
        self.radiance = radiance
        self.intensity = intensity
        self.castShadows = castShadows
        self.range = range
        self.innerConeAngle = innerConeAngle
        self.outerConeAngle = outerConeAngle
        self.shadowBias = shadowBias
        self.shadowSlopeBias = shadowSlopeBias
        self.shadowPriority = shadowPriority
    }
    private enum CodingKeys: CodingKey { case radiance, intensity, castShadows, range, innerConeAngle, outerConeAngle, shadowBias, shadowSlopeBias, shadowPriority }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            radiance: try decodeLocalLightRadiance(values, key: .radiance),
            intensity: try values.decodeIfPresent(Float.self, forKey: .intensity) ?? 1,
            castShadows: try values.decodeIfPresent(Bool.self, forKey: .castShadows) ?? true,
            range: try values.decodeIfPresent(Float.self, forKey: .range) ?? 10,
            innerConeAngle: try values.decodeIfPresent(Float.self, forKey: .innerConeAngle) ?? 20,
            outerConeAngle: try values.decodeIfPresent(Float.self, forKey: .outerConeAngle) ?? 35,
            shadowBias: try values.decodeIfPresent(Float.self, forKey: .shadowBias) ?? 0.002,
            shadowSlopeBias: try values.decodeIfPresent(Float.self, forKey: .shadowSlopeBias) ?? 0.004,
            shadowPriority: try values.decodeIfPresent(Int.self, forKey: .shadowPriority) ?? 0
        )
    }
}

/// An omnidirectional local light. The range is in world meters and is independent of entity scale.
@Component
public struct PointLightComponent: Codable, Sendable {
    public var radiance: Vector3
    /// Linear radiance multiplier at one meter, before range attenuation.
    public var intensity: Float
    public var castShadows: Bool
    public var range: Float = 10
    public var shadowBias: Float = 0.002
    public var shadowSlopeBias: Float = 0.004
    public var shadowPriority: Int = 0

    public init(
        radiance: Vector3 = .one,
        intensity: Float = 1,
        castShadows: Bool = true,
        range: Float = 10,
        shadowBias: Float = 0.002,
        shadowSlopeBias: Float = 0.004,
        shadowPriority: Int = 0
    ) {
        self.radiance = radiance
        self.intensity = intensity
        self.castShadows = castShadows
        self.range = range
        self.shadowBias = shadowBias
        self.shadowSlopeBias = shadowSlopeBias
        self.shadowPriority = shadowPriority
    }
    private enum CodingKeys: CodingKey { case radiance, intensity, castShadows, range, shadowBias, shadowSlopeBias, shadowPriority }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            radiance: try decodeLocalLightRadiance(values, key: .radiance),
            intensity: try values.decodeIfPresent(Float.self, forKey: .intensity) ?? 1,
            castShadows: try values.decodeIfPresent(Bool.self, forKey: .castShadows) ?? true,
            range: try values.decodeIfPresent(Float.self, forKey: .range) ?? 10,
            shadowBias: try values.decodeIfPresent(Float.self, forKey: .shadowBias) ?? 0.002,
            shadowSlopeBias: try values.decodeIfPresent(Float.self, forKey: .shadowSlopeBias) ?? 0.004,
            shadowPriority: try values.decodeIfPresent(Int.self, forKey: .shadowPriority) ?? 0
        )
    }
}

/// An infinitely distant light. Its local +Z axis is the direction the light rays travel.
@Component
public struct DirectionalLightComponent: Sendable {
    public var radiance: Vector3
    public var intensity: Float
    public var castShadows: Bool
    public var shadowDistance: Float
    public var shadowBias: Float
    public var shadowSlopeBias: Float

    public init(
        radiance: Vector3 = .one,
        intensity: Float = 1,
        castShadows: Bool = true,
        shadowDistance: Float = 30,
        shadowBias: Float = 0.0008,
        shadowSlopeBias: Float = 0.003
    ) {
        self.radiance = radiance
        self.intensity = intensity
        self.castShadows = castShadows
        self.shadowDistance = shadowDistance
        self.shadowBias = shadowBias
        self.shadowSlopeBias = shadowSlopeBias
    }
}

private func decodeLocalLightRadiance<Key: CodingKey>(_ values: KeyedDecodingContainer<Key>, key: Key) throws -> Vector3 {
    if let array = try? values.decode([Float].self, forKey: key), array.count == 3 {
        return Vector3(array[0], array[1], array[2])
    }
    return try values.decodeIfPresent(Vector3.self, forKey: key) ?? .one
}
