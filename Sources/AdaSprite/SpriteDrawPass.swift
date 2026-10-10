//
//  SpriteDrawPass.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/23/23.
//

import AdaCorePipelines
import AdaECS
import AdaRender
import AdaUtils
import Math

public struct SpriteVertexData: Sendable {
    public let position: Vector4
    public let color: Color
    public let textureCoordinate: Vector2

    public init(position: Vector4, color: Color, textureCoordinate: Vector2) {
        self.position = position
        self.color = color
        self.textureCoordinate = textureCoordinate
    }
}

/// Render draw pass for rendering sprites. Support batching.
///
/// Batching works by grouping sprites with the same texture together
/// and drawing contiguous quads with one draw. Capable devices use a shared quad
/// and per-instance data; other devices retain pre-transformed vertices.
public struct SpriteDrawPass: DrawPass {
    enum ShaderSlots {
        static let texture = 0
        static let sampler = 1
        static let vertexBuffer = 0
    }

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view _: Entity,
        item: Transparent2DRenderItem
    ) throws {
        guard
            let spritesData = world.getResource(SpriteDrawData.self),
            let spriteBatches = world.getResource(SpriteBatches.self),
            let range = item.batchRange, !range.isEmpty
        else {
            return
        }

        guard let batch = spriteBatches.batches[item.entity] else {
            return
        }

        renderEncoder.pushDebugName("SpriteDrawPass")
        defer {
            renderEncoder.popDebugName()
        }

        let resourceSet = RenderResourceSet(
            bindings: [
                RenderResourceSet.Binding(
                    binding: ShaderSlots.texture,
                    shaderStages: .fragment,
                    resource: .texture(batch.texture)
                ),
                RenderResourceSet.Binding(
                    binding: ShaderSlots.sampler,
                    shaderStages: .fragment,
                    resource: .sampler(batch.texture.sampler)
                ),
            ]
        )
        renderEncoder.setResourceSet(resourceSet, index: 0)
        renderEncoder.setRenderPipelineState(item.renderPipeline)
        if spritesData.usesInstancing {
            renderEncoder.setVertexBuffer(spritesData.instancing.quad, offset: 0, slot: ShaderSlots.vertexBuffer)
            renderEncoder.setVertexBuffer(
                spritesData.instancing.instances,
                offset: Int(range.lowerBound) * MemoryLayout<SpriteInstanceData>.stride,
                slot: 1
            )
            renderEncoder.setIndexBuffer(spritesData.instancing.indices, indexFormat: .uInt32)
            renderEncoder.drawIndexed(indexCount: 6, indexBufferOffset: 0, instanceCount: range.count)
            return
        }
        renderEncoder.setVertexBuffer(spritesData.vertexBuffer, offset: 0, slot: ShaderSlots.vertexBuffer)
        renderEncoder.setIndexBuffer(spritesData.indexBuffer, indexFormat: .uInt32)

        let instanceCount = range.count
        let indexBufferOffset = Int(range.lowerBound) * MemoryLayout<UInt32>.stride
        renderEncoder.drawIndexed(
            indexCount: 6 * instanceCount,
            indexBufferOffset: 6 * indexBufferOffset,
            instanceCount: 1
        )
    }
}
