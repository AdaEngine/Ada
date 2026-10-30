import Foundation

/// One-bounce diffuse transport from visible, directly lit surfaces and emitters.
/// Off-screen geometry and hidden light paths require baked lighting or a world-space GI system.
public struct ScreenSpaceGI3D: Codable, Sendable, Equatable {
    public var isEnabled: Bool
    public var intensity: Float
    public var maxDistance: Float
    public var thickness: Float
    public var bias: Float
    public var rayCount: Int
    public var stepCount: Int
    public var maximumRadiance: Float

    public init(isEnabled: Bool = false, intensity: Float = 1, maxDistance: Float = 5,
                thickness: Float = 0.15, bias: Float = 0.04, rayCount: Int = 8,
                stepCount: Int = 16, maximumRadiance: Float = 16) {
        self.isEnabled = isEnabled; self.intensity = intensity; self.maxDistance = maxDistance
        self.thickness = thickness; self.bias = bias; self.rayCount = rayCount
        self.stepCount = stepCount; self.maximumRadiance = maximumRadiance
    }

    var sanitized: Self {
        .init(isEnabled: isEnabled, intensity: finiteRenderValue(intensity, fallback: 1, range: 0...4),
              maxDistance: finiteRenderValue(maxDistance, fallback: 5, range: 0.1...50),
              thickness: finiteRenderValue(thickness, fallback: 0.15, range: 0.005...2),
              bias: finiteRenderValue(bias, fallback: 0.04, range: 0.002...0.5),
              rayCount: min(max(rayCount, 1), 16), stepCount: min(max(stepCount, 4), 32),
              maximumRadiance: finiteRenderValue(maximumRadiance, fallback: 16, range: 0.1...1000))
    }

    private enum CodingKeys: CodingKey { case isEnabled, intensity, maxDistance, thickness, bias, rayCount, stepCount, maximumRadiance }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self), d = Self()
        self.init(isEnabled: try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? d.isEnabled,
                  intensity: try c.decodeIfPresent(Float.self, forKey: .intensity) ?? d.intensity,
                  maxDistance: try c.decodeIfPresent(Float.self, forKey: .maxDistance) ?? d.maxDistance,
                  thickness: try c.decodeIfPresent(Float.self, forKey: .thickness) ?? d.thickness,
                  bias: try c.decodeIfPresent(Float.self, forKey: .bias) ?? d.bias,
                  rayCount: try c.decodeIfPresent(Int.self, forKey: .rayCount) ?? d.rayCount,
                  stepCount: try c.decodeIfPresent(Int.self, forKey: .stepCount) ?? d.stepCount,
                  maximumRadiance: try c.decodeIfPresent(Float.self, forKey: .maximumRadiance) ?? d.maximumRadiance)
    }
}
