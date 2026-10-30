import Math

public enum TemporalReconstructionMethod: String, Codable, Sendable {
    /// Native MetalFX or DLSS; preserves the original unsupported-device behavior.
    case automatic
    /// Vendor-independent shader reconstruction (TAA at scale 1, temporal upscaling below 1).
    case portable
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
        self.init(renderScale: try c.decodeIfPresent(Float.self, forKey: .renderScale) ?? 0.75,
            resetGeneration: try c.decodeIfPresent(UInt64.self, forKey: .resetGeneration) ?? 0,
            method: try c.decodeIfPresent(TemporalReconstructionMethod.self, forKey: .method) ?? .automatic)
    }
}

/// Backend-owned history. Create one instance per source camera, never share it between views.
public protocol TemporalUpscaler: AnyObject, Sendable {
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
