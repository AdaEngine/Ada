import AdaAssets
import AdaECS
import AdaRender
import AdaSprite

struct TileMapChunkPipeline: RenderPipelineConfigurator, WorldInitable {
    let shader: AssetHandle<ShaderModule>

    init(from _: World) {
        shader = ShaderModule.loadRequiredBundled(at: "Assets/tilemap_chunk.glsl", from: .adaModule)
    }

    func configurate(with _: RenderPipelineEmptyConfiguration) -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: shader.asset.requiredShader(for: .vertex))
        descriptor.fragment = shader.asset.getShader(for: .fragment)
        descriptor.debugName = "Tile map chunk"
        descriptor.backfaceCulling = false
        descriptor.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate")
        ])
        descriptor.vertexDescriptor.layouts[0].stride = MemoryLayout<SpriteVertexData>.stride
        descriptor.colorAttachments = [.init(format: .bgra8, isBlendingEnabled: true)]
        return descriptor
    }
}
