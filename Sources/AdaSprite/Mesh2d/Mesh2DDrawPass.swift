//
//  Mesh2DDrawPass.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/2/23.
//

import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import Math

struct Mesh2DUniform {
    let model: Transform3D
    let modelInverseTranspose: Transform3D
}

/// Contians logic for drawing 2D Meshes.
public struct Mesh2DDrawPass: DrawPass {
    public typealias Item = Transparent2DRenderItem

    public static let meshUniformBinding: Int = 3

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view: Entity,
        item: Transparent2DRenderItem
    ) throws {
        guard let entity = world.getEntityByID(item.entity) else {
            return
        }
        guard let meshComponent = entity.components[ExctractedMeshPart2d.self] else {
            return
        }
        var part = meshComponent.part
        guard let materialData = unsafe MaterialStorage.shared.getMaterialData(for: meshComponent.material) else {
            return
        }

        renderEncoder.pushDebugName("Mesh 2D Render")
        defer {
            renderEncoder.popDebugName()
        }

        for (groupIndex, descriptorSet) in materialData.reflectionData.descriptorSets.enumerated() {
            var bindings: [RenderResourceSet.Binding] = []

            for (_, buffer) in descriptorSet.uniformsBuffers {
                guard let uniformBuffer = materialData.uniformBufferSet[buffer.name] else {
                    continue
                }

                bindings.append(
                    RenderResourceSet.Binding(
                        binding: buffer.binding,
                        shaderStages: buffer.shaderStage,
                        resource: .uniformBuffer(uniformBuffer, offset: 0)
                    )
                )
            }

            for (_, sampler) in descriptorSet.sampledImages {
                guard let materialTexture = materialData.textures[sampler.name] else {
                    continue
                }

                bindings.append(
                    RenderResourceSet.Binding(
                        binding: sampler.binding,
                        shaderStages: sampler.shaderStage,
                        arrayLength: sampler.arraySize,
                        resource: .texture(materialTexture.texture)
                    )
                )

                if let samplerResource = materialData.reflectionData.samplers[materialTexture.samplerName] {
                    bindings.append(
                        RenderResourceSet.Binding(
                            binding: samplerResource.binding,
                            shaderStages: samplerResource.shaderStage,
                            resource: .sampler(materialTexture.texture.sampler)
                        )
                    )
                }
            }

            if !bindings.isEmpty {
                renderEncoder.setResourceSet(RenderResourceSet(bindings: bindings), index: groupIndex)
            }
        }

        // Reflected materials can include AE_GlobalView with their own empty buffer.
        // Restore the actual view after binding material resources, just as we do for the model.
        if let viewUniform = view.components[GlobalViewUniform.self] {
            renderEncoder.setVertexBuffer(viewUniform, slot: GlobalBufferIndex.viewUniform)
        }
        renderEncoder.setVertexBuffer(meshComponent.modelUniform, slot: Self.meshUniformBinding)

        part.vertexBuffer.label = "Part Vertex Buffer"
        renderEncoder.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(part.indexBuffer, offset: 0)
        renderEncoder.setRenderPipelineState(item.renderPipeline)

        renderEncoder.drawIndexed(
            indexCount: part.indexCount,
            indexBufferOffset: 0,
            instanceCount: 1
        )
    }
}

extension Mesh.PrimitiveTopology {
    var indexPrimitive: IndexPrimitive {
        switch self {
        case .points:
            return .points
        case .triangleList:
            return .triangle
        case .triangleStrip:
            return .triangleStrip
        case .lineList:
            return .line
        case .lineStrip:
            return .lineStrip
        }
    }
}
