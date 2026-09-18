import AdaAssets
import AdaECS
import AdaRender

/// Pipeline that renders opaque mesh depth into the primary directional-light shadow map.
public struct DirectionalShadow3DPipeline: RenderPipelineConfigurator {
    private let shader: AssetHandle<ShaderModule>

    public init() {
        self.shader = ShaderModule.loadRequiredBundled(at: "Shaders/directional_shadow_3d.glsl", from: .module)
    }

    public func configurate(with configuration: VertexDescriptor) -> RenderPipelineDescriptor {
        var configuration = configuration
        configuration.attributes[5] = .attribute(.vector4, name: "instanceModel0", bufferIndex: 3, offset: 0)
        configuration.attributes[6] = .attribute(.vector4, name: "instanceModel1", bufferIndex: 3, offset: 16)
        configuration.attributes[7] = .attribute(.vector4, name: "instanceModel2", bufferIndex: 3, offset: 32)
        configuration.attributes[8] = .attribute(.vector4, name: "instanceModel3", bufferIndex: 3, offset: 48)
        configuration.layouts[3] = VertexDescriptor.Layout(
            stride: MemoryLayout<Flat3DInstanceData>.stride,
            stepFunction: .perInstance
        )

        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.debugName = "Directional Shadow 3D Pipeline"
        descriptor.vertexDescriptor = configuration
        descriptor.depthStencilDescriptor = DepthStencilDescriptor(
            isDepthTestEnabled: true,
            isDepthWriteEnabled: true,
            depthCompareOperator: .less
        )
        descriptor.colorAttachments = [RenderPipelineColorAttachmentDescriptor(format: .rgba_32f)]
        return descriptor
    }
}
