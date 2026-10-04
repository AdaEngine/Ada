import AdaECS
import AdaRender

public struct PBR3DConfiguration: Hashable, Sendable {
    public let vertex: VertexDescriptor
    public let blended: Bool

    public init(vertex: VertexDescriptor, blended: Bool) {
        self.vertex = vertex
        self.blended = blended
    }
}

/// Fragment-stage facing handling keeps single/double-sided behavior consistent across backends.
public struct PBR3DPipeline: RenderPipelineConfigurator {
    private let base = Flat3DPipeline()
    public init() {}

    public func configurate(with configuration: PBR3DConfiguration) -> RenderPipelineDescriptor {
        var descriptor = base.configurate(with: configuration.vertex)
        descriptor.backfaceCulling = false
        descriptor.depthStencilDescriptor?.isDepthWriteEnabled = !configuration.blended
        return descriptor
    }
}
