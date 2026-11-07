import Foundation
import Math

/// One artist-authored canonical sample, addressed within a 256-cell region.
/// The explicit override blends with automatic rules; zero override reveals those rules.
public struct TerrainRegionSurfaceSample: Equatable, Sendable {
    public let x: UInt8
    public let z: UInt8
    public let layerIDs: SIMD4<UInt16>
    public let weights: Vector4
    public let overrideStrength: Float
    public let tint: Vector4
    public let tintStrength: Float
    public let roughness: Float
    public let roughnessStrength: Float

    public init(
        x: UInt8,
        z: UInt8,
        layerIDs: SIMD4<UInt16> = .zero,
        weights: Vector4 = .zero,
        overrideStrength: Float = 0,
        tint: Vector4 = .one,
        tintStrength: Float = 0,
        roughness: Float = 1,
        roughnessStrength: Float = 0
    ) {
        self.x = x; self.z = z; self.layerIDs = layerIDs; self.weights = weights; self.overrideStrength = overrideStrength
        self.tint = tint; self.tintStrength = tintStrength; self.roughness = roughness; self.roughnessStrength = roughnessStrength
    }

    func validate(allowEmpty: Bool = false) throws {
        func unit(_ value: Float) -> Bool { value.isFinite && (0...1).contains(value) }
        guard unit(overrideStrength), unit(tintStrength), unit(roughness), unit(roughnessStrength),
            allowEmpty || overrideStrength > 0 || tintStrength > 0 || roughnessStrength > 0
        else { throw TerrainRegionError.malformed("invalid or empty surface override") }
        var total: Float = 0
        for channel in 0..<4 {
            guard unit(weights[channel]), unit(tint[channel]) else { throw TerrainRegionError.malformed("invalid surface channels") }
            if weights[channel] > 0 {
                for previous in 0..<channel where weights[previous] > 0 {
                    guard layerIDs[previous] != layerIDs[channel] else { throw TerrainRegionError.malformed("duplicate painted layer") }
                }
            }
            total += weights[channel]
        }
        guard overrideStrength == 0 ? total == 0 : abs(total - 1) <= 0.0001 else {
            throw TerrainRegionError.malformed("paint weights must be normalized")
        }
    }
}

/// A nonzero artist-authored rule mask at one canonical sample; absence means zero.
public struct TerrainRegionRuleMaskSample: Equatable, Sendable {
    public let x: UInt8
    public let z: UInt8
    public let maskID: UInt16
    public let value: Float

    public init(x: UInt8, z: UInt8, maskID: UInt16, value: Float) {
        self.x = x; self.z = z; self.maskID = maskID; self.value = value
    }

    func validate() throws {
        guard value.isFinite, value > 0, value <= 1 else { throw TerrainRegionError.malformed("invalid or empty rule mask") }
    }
}
