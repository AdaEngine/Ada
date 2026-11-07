import AdaECS

/// Connects a hosted model's resolved file path with its authored project resource.
public struct MeshTerrain3DSourceModelResource: Component, Sendable {
    public let resolvedPath: String
    public let resourcePath: String

    public init(resolvedPath: String, resourcePath: String) {
        self.resolvedPath = resolvedPath
        self.resourcePath = resourcePath
    }
}
