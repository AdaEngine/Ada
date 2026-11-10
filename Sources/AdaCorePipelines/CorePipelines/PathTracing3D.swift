import Foundation

/// How a path-traced view removes the noise of its few samples per pixel.
public enum PathTracingDenoiser: String, Codable, Sendable, CaseIterable {
    /// DLSS Ray Reconstruction where the device supports it and the camera uses DLSS temporal upscaling;
    /// the portable denoiser everywhere else.
    case automatic
    /// DLSS Ray Reconstruction; falls back to ``portable`` with a status reason when unavailable.
    case rayReconstruction
    /// Temporal reprojection and an edge-aware wavelet filter, on every backend.
    case portable
    /// Plain accumulation of a still view, which any camera, light or scene change restarts. For reference renders.
    case off
}

/// Experimental world-space path tracing on the portable GPU backend.
/// Intersections run in a shader BVH; this does not claim hardware RT acceleration.
public struct PathTracing3D: Codable, Equatable, Sendable {
    public var isEnabled: Bool = false
    public var samplesPerPixel: Int = 1
    /// Number of surface interactions, including the directly visible surface.
    public var maximumBounces: Int = 3
    public var resolutionScale: Float = 0.5
    /// Material atlas tile size, bounded to 128...512 pixels. Higher values retain more texture detail.
    public var textureTileSize: Int = 128
    public var maximumDistance: Float = 200
    public var maximumRadiance: Float = 64
    /// Frames accumulated by the `.off` denoiser, whose history any camera, geometry, material or light change restarts.
    /// The portable denoiser's history is bounded by ``minimumHistoryWeight`` instead.
    public var historyLimit: Int = 32
    public var rayBias: Float = 0.002
    /// Denoiser selection. See ``PathTracingDenoiser``.
    public var denoiser: PathTracingDenoiser = .automatic
    /// Smallest weight a new frame gets in the portable denoiser's history. Smaller values converge to less noise
    /// in still views; larger ones follow moving lights faster.
    public var minimumHistoryWeight: Float = 1.0 / 32

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
        result.textureTileSize = textureTileSize >= 512 ? 512 : (textureTileSize >= 256 ? 256 : 128)
        result.maximumBounces = min(max(maximumBounces, 1), 8)
        result.resolutionScale = finiteRenderValue(resolutionScale, fallback: 0.5, range: 0.125...1)
        result.maximumDistance = finiteRenderValue(maximumDistance, fallback: 200, range: 1...10000)
        result.maximumRadiance = finiteRenderValue(maximumRadiance, fallback: 64, range: 1...10000)
        result.rayBias = finiteRenderValue(rayBias, fallback: 0.002, range: 0.0001...0.1)
        result.historyLimit = min(max(historyLimit, 1), 1024)
        result.minimumHistoryWeight = finiteRenderValue(minimumHistoryWeight, fallback: 1.0 / 32, range: 0.005...1)
        return result
    }

    private enum CodingKeys: CodingKey {
        case isEnabled, samplesPerPixel, maximumBounces, resolutionScale, textureTileSize, maximumDistance, maximumRadiance, historyLimit, rayBias
        case denoiser, minimumHistoryWeight
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try c.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        samplesPerPixel = try c.decodeIfPresent(Int.self, forKey: .samplesPerPixel) ?? 1
        maximumBounces = try c.decodeIfPresent(Int.self, forKey: .maximumBounces) ?? 3
        resolutionScale = try c.decodeIfPresent(Float.self, forKey: .resolutionScale) ?? 0.5
        textureTileSize = try c.decodeIfPresent(Int.self, forKey: .textureTileSize) ?? 128
        maximumDistance = try c.decodeIfPresent(Float.self, forKey: .maximumDistance) ?? 200
        maximumRadiance = try c.decodeIfPresent(Float.self, forKey: .maximumRadiance) ?? 64
        historyLimit = try c.decodeIfPresent(Int.self, forKey: .historyLimit) ?? 32
        rayBias = try c.decodeIfPresent(Float.self, forKey: .rayBias) ?? 0.002
        denoiser = try c.decodeIfPresent(PathTracingDenoiser.self, forKey: .denoiser) ?? .automatic
        minimumHistoryWeight = try c.decodeIfPresent(Float.self, forKey: .minimumHistoryWeight) ?? 1.0 / 32
    }
}
