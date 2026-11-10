import AdaECS

/// Chooses which geometry the path tracer traces, for an entity and its descendants.
///
/// Path tracing takes its first hit from the raster G-buffer, so a scene can raster a detailed model while
/// the tracer intersects a lighter proxy for bounces and shadows:
///
/// ```swift
/// detailed.components += PathTracingGeometry3D.rasterOnly
/// proxy.components += PathTracingGeometry3D.pathTracingOnly
/// ```
///
/// Without the component a mesh is both drawn and traced. A descendant's own value overrides its ancestors'.
@Component
public enum PathTracingGeometry3D: Codable, Sendable, Equatable {
    /// Drawn by raster passes; the path tracer does not intersect it.
    case rasterOnly
    /// Intersected by the path tracer only; raster passes, shadows and visibility never see it.
    case pathTracingOnly
}
