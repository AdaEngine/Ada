import Foundation

public enum ShadowFilter3D: String, Codable, Sendable { case pcf, pcss }

/// Screen-space visibility supplement for the primary sun and shadow-atlas local lights.
public struct ContactShadows3D: Codable, Equatable, Sendable {
    public var isEnabled: Bool
    public var rayLength: Float
    public var thickness: Float
    public var bias: Float
    public var steps: Int
    public var maxDistance: Float
    public init(isEnabled: Bool = false, rayLength: Float = 0.3, thickness: Float = 0.05,
                bias: Float = 0.012, steps: Int = 16, maxDistance: Float = 30) {
        self.isEnabled = isEnabled; self.rayLength = rayLength; self.thickness = thickness
        self.bias = bias; self.steps = steps; self.maxDistance = maxDistance
    }
    var sanitized: Self {
        .init(isEnabled: isEnabled, rayLength: finiteRenderValue(rayLength,fallback:0.3,range:0.02...2),
              thickness: finiteRenderValue(thickness,fallback:0.05,range:0.002...0.5),
              bias: finiteRenderValue(bias,fallback:0.012,range:0.001...0.2), steps:min(max(steps,4),32),
              maxDistance:finiteRenderValue(maxDistance,fallback:30,range:1...500))
    }
    private enum CodingKeys: CodingKey { case isEnabled, rayLength, thickness, bias, steps, maxDistance }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self), d = Self()
        self.init(isEnabled:try c.decodeIfPresent(Bool.self,forKey:.isEnabled) ?? d.isEnabled,
            rayLength:try c.decodeIfPresent(Float.self,forKey:.rayLength) ?? d.rayLength,
            thickness:try c.decodeIfPresent(Float.self,forKey:.thickness) ?? d.thickness,
            bias:try c.decodeIfPresent(Float.self,forKey:.bias) ?? d.bias,
            steps:try c.decodeIfPresent(Int.self,forKey:.steps) ?? d.steps,
            maxDistance:try c.decodeIfPresent(Float.self,forKey:.maxDistance) ?? d.maxDistance)
    }
}

/// Directional shadow quality. One cascade preserves the original coverage; up to three fit camera frustum slices.
public struct ShadowSettings3D: Codable, Sendable {
    public var isEnabled: Bool
    public var cascadeCount: Int
    public var splitLambda: Float
    public var blendFraction: Float
    /// Pixels per cascade. Existing scenes retain their original allocation.
    public var resolution: Int
    public var filter: ShadowFilter3D = .pcf
    /// Angular radius of the directional emitter, in degrees. The sun is approximately 0.27 degrees.
    public var lightAngularRadius: Float = 0.27
    public var maximumPenumbraTexels: Float = 16
    public var blockerSearchTexels: Float = 8

    public init(isEnabled: Bool = true, cascadeCount: Int = 1, splitLambda: Float = 0.65, blendFraction: Float = 0.1, resolution: Int = 1024) {
        self.isEnabled = isEnabled
        self.cascadeCount = cascadeCount
        self.splitLambda = splitLambda
        self.blendFraction = blendFraction
        self.resolution = resolution
    }

    private enum CodingKeys: String, CodingKey { case isEnabled, cascadeCount, splitLambda, blendFraction, resolution, filter, lightAngularRadius, maximumPenumbraTexels, blockerSearchTexels }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            isEnabled: try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true,
            cascadeCount: try values.decodeIfPresent(Int.self, forKey: .cascadeCount) ?? 1,
            splitLambda: try values.decodeIfPresent(Float.self, forKey: .splitLambda) ?? 0.65,
            blendFraction: try values.decodeIfPresent(Float.self, forKey: .blendFraction) ?? 0.1,
            resolution: try values.decodeIfPresent(Int.self, forKey: .resolution) ?? 1024
        )
        filter = try values.decodeIfPresent(ShadowFilter3D.self, forKey: .filter) ?? .pcf
        lightAngularRadius = try values.decodeIfPresent(Float.self, forKey: .lightAngularRadius) ?? 0.27
        maximumPenumbraTexels = try values.decodeIfPresent(Float.self, forKey: .maximumPenumbraTexels) ?? 16
        blockerSearchTexels = try values.decodeIfPresent(Float.self, forKey: .blockerSearchTexels) ?? 8
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
