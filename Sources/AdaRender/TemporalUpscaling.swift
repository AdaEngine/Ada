import Math

public enum TemporalReconstructionMethod: String, Codable, Sendable {
    /// DLSS when it is available, otherwise the vendor-independent `.portable` reconstruction.
    case automatic
    /// Vendor-independent shader reconstruction (TAA at scale 1, temporal upscaling below 1).
    case portable
    /// NVIDIA DLSS Super Resolution. Falls back to ``portable`` with a reason when DLSS is unavailable.
    case dlss
}

/// The method that actually runs for a camera, and why a requested method was not used.
public struct TemporalReconstructionResolution: Equatable, Sendable {
    public var method: TemporalReconstructionMethod
    public var fallbackReason: String?
}

extension TemporalReconstructionMethod {
    /// Applies DLSS availability to the requested method.
    ///
    /// `.automatic` uses DLSS when available and otherwise the builtin `.portable` reconstruction.
    /// `.dlss` uses DLSS when available and otherwise falls back to ``portable`` with `unavailableReason`.
    public func resolved(dlssAvailable: Bool, unavailableReason: String?) -> TemporalReconstructionResolution {
        switch self {
        case .automatic:
            return TemporalReconstructionResolution(method: dlssAvailable ? .dlss : .portable, fallbackReason: nil)
        case .portable:
            return TemporalReconstructionResolution(method: .portable, fallbackReason: nil)
        case .dlss:
            return dlssAvailable
                ? TemporalReconstructionResolution(method: .dlss, fallbackReason: nil)
                : TemporalReconstructionResolution(method: .portable, fallbackReason: unavailableReason ?? "DLSS is unavailable")
        }
    }
}

/// Per-camera temporal reconstruction. Unsupported devices use spatial scaling or native resolution.
public struct TemporalUpscalingSettings: Codable, Equatable, Sendable {
    public var renderScale: Float
    public var resetGeneration: UInt64
    public var method: TemporalReconstructionMethod

    public init(renderScale: Float = 0.75, resetGeneration: UInt64 = 0, method: TemporalReconstructionMethod = .automatic) {
        self.renderScale = renderScale
        self.resetGeneration = resetGeneration
        self.method = method
    }
    private enum CodingKeys: CodingKey { case renderScale, resetGeneration, method }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            renderScale: try c.decodeIfPresent(Float.self, forKey: .renderScale) ?? 0.75,
            resetGeneration: try c.decodeIfPresent(UInt64.self, forKey: .resetGeneration) ?? 0,
            method: try c.decodeIfPresent(TemporalReconstructionMethod.self, forKey: .method) ?? .automatic
        )
    }
}

/// Surface guides of a path-traced frame for denoising reconstruction (DLSS Ray Reconstruction), at input size.
public struct RayReconstructionGuides: Sendable {
    /// RGBA16Float: diffuse albedo, specular albedo, and world-space normal with roughness in alpha.
    public var diffuseAlbedo: Texture
    public var specularAlbedo: Texture
    public var normalRoughness: Texture
    /// Optional R32Float distance to the first specular hit, in world units.
    public var specularHitDistance: Texture?
    /// Unjittered world-to-view and view-to-clip transforms of the frame.
    public var worldToView: Transform3D
    public var viewToClip: Transform3D
    /// The tracer restarted its history (scene, light set, settings or denoiser change): reset reconstruction too.
    public var reset: Bool

    public init(
        diffuseAlbedo: Texture,
        specularAlbedo: Texture,
        normalRoughness: Texture,
        worldToView: Transform3D,
        viewToClip: Transform3D,
        reset: Bool = false,
        specularHitDistance: Texture? = nil
    ) {
        self.diffuseAlbedo = diffuseAlbedo
        self.specularAlbedo = specularAlbedo
        self.normalRoughness = normalRoughness
        self.specularHitDistance = specularHitDistance
        self.worldToView = worldToView
        self.viewToClip = viewToClip
        self.reset = reset
    }
}

/// Backend-owned history. Create one instance per source camera, never share it between views.
public protocol TemporalUpscaler: AnyObject, Sendable {
    /// Whether ``encodeDenoised(commandBuffer:color:depth:motion:reactive:guides:output:jitter:reset:)`` can succeed.
    var supportsDenoising: Bool { get }
    /// Whether this instance accepts the optional specular hit-distance texture.
    var supportsSpecularHitDistance: Bool { get }

    /// Denoises and reconstructs a noisy path-traced frame; false means the caller must use ``encode`` instead.
    func encodeDenoised(
        commandBuffer: CommandBuffer,
        color: Texture,
        depth: Texture,
        motion: Texture,
        reactive: Texture,
        guides: RayReconstructionGuides,
        output: Texture,
        jitter: Vector2,
        reset: Bool
    ) -> Bool

    /// Encodes reconstruction; false means the caller must present a spatial fallback.
    func encode(
        commandBuffer: CommandBuffer,
        color: Texture,
        depth: Texture,
        motion: Texture,
        reactive: Texture,
        output: Texture,
        jitter: Vector2,
        reset: Bool
    ) -> Bool
}

extension TemporalUpscaler {
    public var supportsDenoising: Bool { false }
    public var supportsSpecularHitDistance: Bool { false }

    public func encodeDenoised(
        commandBuffer _: CommandBuffer,
        color _: Texture,
        depth _: Texture,
        motion _: Texture,
        reactive _: Texture,
        guides _: RayReconstructionGuides,
        output _: Texture,
        jitter _: Vector2,
        reset _: Bool
    ) -> Bool { false }
}
