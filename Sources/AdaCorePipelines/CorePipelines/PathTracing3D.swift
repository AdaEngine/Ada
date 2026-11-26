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

/// How a path-traced view estimates lighting at each surface.
public enum PathTracingTransport: String, Codable, Sendable, CaseIterable {
    /// Evaluate every analytic light. This is the compatibility and analytic-light reference mode.
    case exhaustive
    /// Sample a bounded set of analytic lights and emissive triangles.
    case interactive
}

/// How a path-traced view finds ray intersections.
public enum PathTracingIntersection: String, Codable, Sendable, CaseIterable {
    /// GPU ray queries when the device and the whole view support them; the shader BVH otherwise.
    case automatic
    /// Always the shader BVH, for reference renders and comparisons.
    case software
}

/// The traversal a view actually uses, and why hardware was not used when it was not.
public struct PathTracingTraversalSelection: Equatable, Sendable {
    public enum Traversal: String, Sendable {
        case hardwareRayQuery = "vulkan-ray-query"
        case softwareBVH = "portable-shader-bvh"
    }
    public var traversal: Traversal
    public var fallbackReason: String?

    /// Whether `.automatic` chooses hardware ray queries when they are available. The measurements behind this are in
    /// `Documentation/Plans/hardware-path-tracing.md`; set it to false to make `.automatic` use the shader BVH.
    static let automaticPrefersHardware = true

    /// Chooses the traversal. `sceneBlocker` names why the scene cannot use hardware (skinned or morphed meshes, budgets,
    /// a failed build), or is nil when it can.
    public static func select(
        _ intersection: PathTracingIntersection,
        deviceSupportsRayQueries: Bool,
        sceneBlocker: String?
    ) -> Self {
        guard intersection == .automatic, automaticPrefersHardware else {
            return Self(traversal: .softwareBVH, fallbackReason: nil)
        }
        guard deviceSupportsRayQueries else {
            return Self(traversal: .softwareBVH, fallbackReason: "The device does not support ray queries")
        }
        if let sceneBlocker {
            return Self(traversal: .softwareBVH, fallbackReason: sceneBlocker)
        }
        return Self(traversal: .hardwareRayQuery, fallbackReason: nil)
    }
}

/// Experimental world-space path tracing with software BVH and, where available, GPU ray queries.
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
    /// Intersection selection. See ``PathTracingIntersection``.
    public var intersection: PathTracingIntersection = .automatic
    /// Controls light selection and the interactive radiance cache.
    public var transport: PathTracingTransport = .exhaustive
    /// Requests the world-space cache when the interactive transport and device support it.
    public var radianceCache: Bool = true
    /// Counts representative GPU cache lookups and updates for on-demand diagnostics.
    public var radianceCacheDiagnostics: Bool = false
    /// Use the raster G-buffer for the first visible surface when supported.
    /// Disable to find the first surface with a ray as well. Ray Reconstruction needs the raster guides.
    public var rasterFirstHit: Bool = true
    /// Smallest weight a new frame gets in the portable denoiser's history. Smaller values converge to less noise
    /// in still views; larger ones follow moving lights faster.
    public var minimumHistoryWeight: Float = 1.0 / 32
    /// How hard the portable denoiser smooths, from 1 (the plain edge-aware filter) to 8. Larger values add a wider
    /// final filter step and smooth pixels with little history, such as around moving objects, much more, at the cost of
    /// softer detail. It does not affect DLSS Ray Reconstruction or plain accumulation.
    public var denoiserStrength: Float = 1

    public init(
        isEnabled: Bool = false,
        samplesPerPixel: Int = 1,
        maximumBounces: Int = 3,
        resolutionScale: Float = 0.5,
        historyLimit: Int = 32
    ) {
        self.isEnabled = isEnabled
        self.samplesPerPixel = samplesPerPixel
        self.maximumBounces = maximumBounces
        self.resolutionScale = resolutionScale
        self.historyLimit = historyLimit
    }

    /// Smallest weight a new frame gets in the portable denoiser's history while objects move.
    static let movingHistoryWeight: Float = 0.1

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
        result.denoiserStrength = finiteRenderValue(denoiserStrength, fallback: 1, range: 1...8)
        return result
    }

    private enum CodingKeys: CodingKey {
        case isEnabled, samplesPerPixel, maximumBounces, resolutionScale, textureTileSize, maximumDistance, maximumRadiance, historyLimit, rayBias
        case denoiser, minimumHistoryWeight, intersection, rasterFirstHit, denoiserStrength
        case transport, radianceCache, radianceCacheDiagnostics
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
        intersection = try c.decodeIfPresent(PathTracingIntersection.self, forKey: .intersection) ?? .automatic
        transport = try c.decodeIfPresent(PathTracingTransport.self, forKey: .transport) ?? .exhaustive
        radianceCache = try c.decodeIfPresent(Bool.self, forKey: .radianceCache) ?? true
        radianceCacheDiagnostics = try c.decodeIfPresent(Bool.self, forKey: .radianceCacheDiagnostics) ?? false
        rasterFirstHit = try c.decodeIfPresent(Bool.self, forKey: .rasterFirstHit) ?? true
        denoiserStrength = try c.decodeIfPresent(Float.self, forKey: .denoiserStrength) ?? 1
    }
}
