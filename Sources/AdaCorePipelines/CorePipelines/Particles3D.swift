import AdaECS
import Math

/// One camera-independent particle; each view creates and sorts its own billboard instances.
public struct Particle3DSample: Sendable {
    public var position: Vector3
    public var size: Float
    public var color: Vector3
    public var opacity: Float
    public var rotation: Float
    public var softDistance: Float
    public var style: Int
    public var aspectRatio: Float
    public var velocity: Vector3
    public init(position: Vector3, size: Float, color: Vector3, opacity: Float, rotation: Float = 0, softDistance: Float = 0.25,
                style: Int = 0, aspectRatio: Float = 1, velocity: Vector3 = .zero) {
        self.position = position; self.size = size; self.color = color
        self.opacity = opacity; self.rotation = rotation; self.softDistance = softDistance
        self.style = style; self.aspectRatio = aspectRatio; self.velocity = velocity
    }
}

/// Render-world snapshot shared by all cameras. No per-particle ECS entities or materials.
public struct ExtractedParticles3D: Resource {
    public var samples: [Particle3DSample] = []
    public init() {}
}
