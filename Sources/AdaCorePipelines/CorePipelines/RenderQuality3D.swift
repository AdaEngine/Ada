import Foundation

/// Directional shadow quality. One cascade preserves the original coverage; up to three fit camera frustum slices.
public struct ShadowSettings3D: Codable, Sendable {
    public var isEnabled: Bool
    public var cascadeCount: Int
    public var splitLambda: Float
    public var blendFraction: Float
    /// Pixels per cascade. Existing scenes retain their original allocation.
    public var resolution: Int

    public init(isEnabled: Bool = true, cascadeCount: Int = 1, splitLambda: Float = 0.65, blendFraction: Float = 0.1, resolution: Int = 1024) {
        self.isEnabled = isEnabled
        self.cascadeCount = cascadeCount
        self.splitLambda = splitLambda
        self.blendFraction = blendFraction
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, cascadeCount, splitLambda, blendFraction, resolution }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            cascadeCount: try values.decodeIfPresent(Int.self, forKey: .cascadeCount) ?? 1,
            splitLambda: try values.decodeIfPresent(Float.self, forKey: .splitLambda) ?? 0.65,
            blendFraction: try values.decodeIfPresent(Float.self, forKey: .blendFraction) ?? 0.1,
            resolution: try values.decodeIfPresent(Int.self, forKey: .resolution) ?? 1024
        )
    }
}

/// View-space contact occlusion. Only the opaque indirect-light contribution is attenuated.
public struct ScreenSpaceAO3D: Codable, Sendable {
    public var isEnabled: Bool
    public var radius: Float
    public var intensity: Float
    public var bias: Float
    public var sampleCount: Int

    public init(isEnabled: Bool = false, radius: Float = 0.65, intensity: Float = 1.1, bias: Float = 0.025, sampleCount: Int = 16) {
        self.isEnabled = isEnabled
        self.radius = radius
        self.intensity = intensity
        self.bias = bias
        self.sampleCount = sampleCount
    }
}

/// Spatial anti-aliasing after HDR tone mapping, before UI and upscaling. No temporal history is used.
public enum AntiAliasing3D: String, Codable, Sendable {
    case none
    case fxaa
}

func finiteRenderValue(_ value: Float, fallback: Float, range: ClosedRange<Float>) -> Float {
    min(max(value.isFinite ? value : fallback, range.lowerBound), range.upperBound)
}
