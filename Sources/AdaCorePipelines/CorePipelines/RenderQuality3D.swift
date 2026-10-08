import Foundation

/// Directional shadow quality. One cascade preserves the original coverage; up to three fit camera frustum slices.
public struct ShadowSettings3D: Codable, Sendable {
    public var isEnabled: Bool
    public var cascadeCount: Int
    public var splitLambda: Float
    public var blendFraction: Float

    public init(isEnabled: Bool = true, cascadeCount: Int = 1, splitLambda: Float = 0.65, blendFraction: Float = 0.1) {
        self.isEnabled = isEnabled
        self.cascadeCount = cascadeCount
        self.splitLambda = splitLambda
        self.blendFraction = blendFraction
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
