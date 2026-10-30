import Foundation

/// Experimental world-space path tracing on the portable GPU backend.
/// Intersections run in a shader BVH; this does not claim hardware RT acceleration.
public struct PathTracing3D: Codable, Equatable, Sendable {
    public var isEnabled: Bool = false
    public var samplesPerPixel: Int = 1
    /// Number of surface interactions, including the directly visible surface.
    public var maximumBounces: Int = 3
    public var resolutionScale: Float = 0.5
    public var maximumDistance: Float = 200
    public var maximumRadiance: Float = 64
    /// Static views accumulate samples; changes to camera, geometry, materials or lights reset history.
    public var historyLimit: Int = 32
    public var rayBias: Float = 0.002

    public init(isEnabled: Bool = false, samplesPerPixel: Int = 1, maximumBounces: Int = 3,
                resolutionScale: Float = 0.5, historyLimit: Int = 32) {
        self.isEnabled = isEnabled
        self.samplesPerPixel = samplesPerPixel
        self.maximumBounces = maximumBounces
        self.resolutionScale = resolutionScale
        self.historyLimit = historyLimit
    }

    var sanitized: Self {
        var result = self
        result.samplesPerPixel = min(max(samplesPerPixel, 1), 8)
        result.maximumBounces = min(max(maximumBounces, 1), 8)
        result.resolutionScale = finiteRenderValue(resolutionScale, fallback: 0.5, range: 0.125...1)
        result.maximumDistance = finiteRenderValue(maximumDistance, fallback: 200, range: 1...10000)
        result.maximumRadiance = finiteRenderValue(maximumRadiance, fallback: 64, range: 1...10000)
        result.rayBias = finiteRenderValue(rayBias, fallback: 0.002, range: 0.0001...0.1)
        result.historyLimit = min(max(historyLimit, 1), 1024)
        return result
    }

    private enum CodingKeys: CodingKey {
        case isEnabled, samplesPerPixel, maximumBounces, resolutionScale, maximumDistance, maximumRadiance, historyLimit, rayBias
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        samplesPerPixel = try c.decodeIfPresent(Int.self, forKey: .samplesPerPixel) ?? 1
        maximumBounces = try c.decodeIfPresent(Int.self, forKey: .maximumBounces) ?? 3
        resolutionScale = try c.decodeIfPresent(Float.self, forKey: .resolutionScale) ?? 0.5
        maximumDistance = try c.decodeIfPresent(Float.self, forKey: .maximumDistance) ?? 200
        maximumRadiance = try c.decodeIfPresent(Float.self, forKey: .maximumRadiance) ?? 64
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 32
        rayBias = try c.decodeIfPresent(Float.self, forKey: .rayBias) ?? 0.002
    }
}
