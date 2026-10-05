import AdaECS
import AdaRender

/// Static mesh alternatives sharing the base mesh's local coordinates and material indices.
/// Thresholds are descending projected diameters as a fraction of viewport height.
/// The base mesh is LOD0; alternatives are LOD1 onward. Skinning keeps LOD0 in this initial path.
public struct MeshLOD3DComponent: Component, Sendable {
    public var alternatives: [Mesh]
    public var screenThresholds: [Float]
    public var hysteresis: Float
    public var maximumDistance: Float?
    public var fadeDistance: Float

    public init(alternatives: [Mesh] = [], screenThresholds: [Float] = [0.18, 0.07], hysteresis: Float = 0.15, maximumDistance: Float? = nil, fadeDistance: Float = 4) {
        self.alternatives = alternatives
        self.screenThresholds = screenThresholds
        self.hysteresis = hysteresis
        self.maximumDistance = maximumDistance
        self.fadeDistance = fadeDistance
    }
}
