import AdaECS
import AdaRender
import AdaUtils

/// Static mesh alternatives sharing the base mesh's local coordinates and material indices.
/// Thresholds are descending projected diameters as a fraction of viewport height.
/// The base mesh is LOD0; alternatives are LOD1 onward. Skinned alternatives require
/// the same ordered palette, local coordinates and material indices.
public struct MeshLOD3DComponent: Component, Sendable {
    /// Author assertion: alternatives preserve the base skin joint order and bind-space geometry.
    /// Influence streams and animated envelopes are validated before these levels are used.
    public var skeletonCompatible = false { didSet { extractionRevision = RID() } }
    public var alternatives: [Mesh] { didSet { extractionRevision = RID() } }
    public var screenThresholds: [Float] { didSet { extractionRevision = RID() } }
    public var hysteresis: Float { didSet { extractionRevision = RID() } }
    public var maximumDistance: Float? { didSet { extractionRevision = RID() } }
    public var fadeDistance: Float { didSet { extractionRevision = RID() } }

    private(set) var extractionRevision = RID()

    public init(alternatives: [Mesh] = [], screenThresholds: [Float] = [0.18, 0.07], hysteresis: Float = 0.15, maximumDistance: Float? = nil, fadeDistance: Float = 4) {
        self.alternatives = alternatives
        self.screenThresholds = screenThresholds
        self.hysteresis = hysteresis
        self.maximumDistance = maximumDistance
        self.fadeDistance = fadeDistance
    }
}
