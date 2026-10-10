import AdaAssets
import AdaECS
import AdaRender
import Math

struct SpriteInstancedRenderPipeline: RenderPipelineConfigurator {
    let shader = ShaderModule.loadRequiredBundled(at: "Assets/sprite_instanced.glsl", from: .adaModule)

    func configurate(with _: RenderPipelineEmptyConfiguration) -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.debugName = "Sprite Instanced Pipeline"
        descriptor.backfaceCulling = false
        descriptor.vertexDescriptor.attributes.append([.attribute(.vector2, name: "a_Corner", bufferIndex: 0)])
        descriptor.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "i_Origin", bufferIndex: 1),
            .attribute(.vector4, name: "i_AxisX", bufferIndex: 1),
            .attribute(.vector4, name: "i_AxisY", bufferIndex: 1),
            .attribute(.vector4, name: "i_Color", bufferIndex: 1),
            .attribute(.vector4, name: "i_BottomUV", bufferIndex: 1),
            .attribute(.vector4, name: "i_TopUV", bufferIndex: 1),
        ])
        descriptor.vertexDescriptor.layouts[0] = .init(stride: MemoryLayout<Vector2>.stride)
        descriptor.vertexDescriptor.layouts[1] = .init(stride: MemoryLayout<SpriteInstanceData>.stride, stepFunction: .perInstance)
        descriptor.colorAttachments = [.init(format: .bgra8, isBlendingEnabled: true)]
        return descriptor
    }
}
