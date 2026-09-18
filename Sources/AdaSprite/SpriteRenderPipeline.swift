//
//  File.swift
//
//
//  Created by v.prusakov on 5/5/24.
//

import AdaAssets
import AdaECS
import AdaRender

public struct SpriteRenderPipeline: RenderPipelineConfigurator {
    public let spriteShader: AssetHandle<ShaderModule>

    public init() {
        self.spriteShader = ShaderModule.loadRequiredBundled(at: "Assets/sprite.glsl", from: .module)
    }
}

extension SpriteRenderPipeline: WorldInitable {
    public init(from _: World) {
        self = Self()
    }
}

extension SpriteRenderPipeline {
    public func configurate(with _: RenderPipelineEmptyConfiguration) -> RenderPipelineDescriptor {
        var piplineDesc = RenderPipelineDescriptor(vertex: spriteShader.asset.requiredShader(for: .vertex))
        piplineDesc.fragment = spriteShader.asset.getShader(for: .fragment)
        piplineDesc.debugName = "Sprite Pipeline"
        piplineDesc.vertexDescriptor.attributes.append([
            .attribute(.vector4, name: "a_Position"),
            .attribute(.vector4, name: "a_Color"),
            .attribute(.vector2, name: "a_TexCoordinate"),
        ])

        piplineDesc.vertexDescriptor.layouts[0].stride = MemoryLayout<SpriteVertexData>.stride
        piplineDesc.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(
                format: .bgra8,
                isBlendingEnabled: true
            )
        ]
        return piplineDesc
    }
}
