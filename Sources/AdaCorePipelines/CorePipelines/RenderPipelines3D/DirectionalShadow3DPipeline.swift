import AdaAssets
import AdaECS
import AdaRender

/// What decides a shadow-pass pipeline: the part's vertex layout and whether its mesh has morph targets.
public struct Shadow3DConfiguration: Hashable, Sendable {
    public let vertex: VertexDescriptor
    public let morph: Bool

    public init(vertex: VertexDescriptor, morph: Bool = false) {
        self.vertex = vertex
        self.morph = morph
    }
}

/// Pipeline that renders opaque mesh depth into the primary directional-light shadow map.
public struct DirectionalShadow3DPipeline: RenderPipelineConfigurator {
    public typealias Configuration = Shadow3DConfiguration

    private let shader: AssetHandle<ShaderModule>
    private let variants = PBR3DShaderVariants()

    public init() {
        self.shader = CorePipelineShaders.loadRequiredBuiltin("directional_shadow_3d")
    }

    /// The pipeline for a part without morph targets.
    public func configurate(with vertex: VertexDescriptor) -> RenderPipelineDescriptor {
        configurate(with: Shadow3DConfiguration(vertex: vertex))
    }

    public func configurate(with shadowConfiguration: Shadow3DConfiguration) -> RenderPipelineDescriptor {
        let shader = shadowConfiguration.morph
            ? variants.shader(
                at: ShaderModule.supportsBundledWESL ? "Shaders/directional_shadow_3d.wesl" : "Shaders/directional_shadow_3d.glsl",
                for: .morph,
                fallback: self.shader
            )
            : self.shader
        var configuration = shadowConfiguration.vertex
        configureSkinningAttributes(&configuration)
        if !configuration.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates.id.name) {
            configuration.attributes[2] = .attribute(.vector2, name: "defaultTextureCoordinate", bufferIndex: 4, offset: 0)
        }
        let defaults = ["defaultJointIndices", "defaultJointWeights", "defaultTextureCoordinate", "defaultTextureCoordinate1", "defaultVertexColor"]
        if defaults.contains(where: { configuration.attributes.containsAttribute(by: $0) }) {
            configuration.layouts[4] = VertexDescriptor.Layout(stride: MemoryLayout<Flat3DDefaultVertexData>.stride, stepFunction: .perInstance)
        }
        configuration.attributes[5] = .attribute(.vector4, name: "instanceModel0", bufferIndex: 3, offset: 0)
        configuration.attributes[6] = .attribute(.vector4, name: "instanceModel1", bufferIndex: 3, offset: 16)
        configuration.attributes[7] = .attribute(.vector4, name: "instanceModel2", bufferIndex: 3, offset: 32)
        configuration.attributes[9] = .attribute(.vector4, name: "instanceColor", bufferIndex: 3, offset: 64)
        configuration.attributes[8] = .attribute(.vector4, name: "instanceModel3", bufferIndex: 3, offset: 48)
        configuration.attributes[12] = .attribute(.vector4, name: "instanceShadowFlags", bufferIndex: 3, offset: 112)
        configuration.layouts[3] = VertexDescriptor.Layout(
            stride: MemoryLayout<Flat3DInstanceData>.stride,
            stepFunction: .perInstance
        )

        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.backfaceCulling = false
        descriptor.debugName = "Directional Shadow 3D Pipeline"
        descriptor.vertexDescriptor = configuration
        #if os(Android)
            descriptor.frontFaceWinding = .clockwise
        #endif
        descriptor.depthStencilDescriptor = DepthStencilDescriptor(
            isDepthTestEnabled: true,
            isDepthWriteEnabled: true,
            depthCompareOperator: .less
        )
        descriptor.colorAttachments = [RenderPipelineColorAttachmentDescriptor(format: .rgba_32f)]
        return descriptor
    }
}
