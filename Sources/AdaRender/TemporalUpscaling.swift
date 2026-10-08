import Math

/// Per-camera temporal reconstruction. Unsupported devices use spatial scaling or native resolution.
public struct TemporalUpscalingSettings: Codable, Equatable, Sendable {
    public var renderScale: Float
    public var resetGeneration: UInt64

    public init(renderScale: Float = 0.75, resetGeneration: UInt64 = 0) {
        self.renderScale = renderScale
        self.resetGeneration = resetGeneration
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
