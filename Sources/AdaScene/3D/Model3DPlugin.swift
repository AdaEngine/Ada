//
//  Model3DPlugin.swift
//  AdaEngine
//
//  Created by v.prusakov on 04/21/26.
//

import AdaApp
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

/// Plugin for extracting 3D models from scene to RenderWorld.
public struct Model3DPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        Mesh3DComponent.registerComponent()
        DirectionalLightComponent.registerComponent()
        PointLightComponent.registerComponent()
        SpotLightComponent.registerComponent()
        BillboardComponent.registerComponent()

        app.addSystem(BillboardSystem.self, on: .update)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        renderWorld
            .insertResource(ExtractedLighting3D())
            .insertResource(RenderItems<Opaque3DRenderItem>())
            .insertResource(Opaque3DInstanceBuffers())
            .insertResource(RenderPipelines(configurator: Flat3DPipeline()))
            .insertResource(Model3DDrawPass())
            .addSystem(ExtractDirectionalLight3DSystem.self, on: .extract)
            .addSystem(ExtractModel3DSystem.self, on: .extract)
    }
}

@System
func ExtractDirectionalLight3D(
    _ query: Extract<Query<Entity, DirectionalLightComponent, GlobalTransform>>,
    _ extracted: ResMut<ExtractedLighting3D>
) {
    extracted.directionalLight = nil
    query.wrappedValue.forEach { _, light, transform in
        guard extracted.directionalLight == nil, light.intensity > 0 else {
            return
        }

        let rayDirection = transform.matrix.z.xyz.normalized
        extracted.directionalLight = ExtractedDirectionalLight3D(
            directionToLight: -rayDirection,
            radiance: light.radiance,
            intensity: light.intensity,
            castsShadows: light.castShadows,
            shadowDistance: light.shadowDistance,
            shadowBias: light.shadowBias,
            shadowSlopeBias: light.shadowSlopeBias
        )
    }
}

@System
func ExtractModel3D(
    _ query: Extract<Query<Entity, Mesh3DComponent, GlobalTransform>>,
    _ renderItems: ResMut<RenderItems<Opaque3DRenderItem>>,
    _ instanceBuffers: ResMut<Opaque3DInstanceBuffers>,
    _ renderDevice: Res<RenderDeviceHandler>,
    _ drawPass: Res<Model3DDrawPass>
) {
    var items = renderItems.items
    items.removeAll(keepingCapacity: true)
    var instances = instanceBuffers.wrappedValue
    instances.beginFrame()
    var currentBatchKey: Opaque3DBatchKey?
    var currentBatchIndex: Int?

    query.wrappedValue.forEach { entity, mesh3d, transform in
        let mesh = mesh3d.mesh
        for (modelIndex, model) in mesh.models.enumerated() {
            for (partIndex, part) in model.parts.enumerated() {
                let material = mesh3d.materials[part.materialIndex]
                let pbrMaterial = material as? PBRMaterial
                let atmosphereMaterial = material as? AtmosphereMaterial
                let hasTextureCoordinates = part.vertexDescriptor.attributes.containsAttribute(
                    by: MeshDescriptor.textureCoordinates.id.name
                )
                let hasTangents = part.vertexDescriptor.attributes.containsAttribute(
                    by: MeshDescriptor.tangents.id.name
                )
                let instanceIndex = instances.append(
                    Flat3DInstanceData(
                        modelMatrix: transform.matrix,
                        color: pbrMaterial?.baseColorFactor ?? .one,
                        material: Vector4(
                            pbrMaterial?.roughnessFactor ?? 1,
                            pbrMaterial?.metallicFactor ?? 0,
                            pbrMaterial?.emissiveTexture == nil ? 0 : pbrMaterial?.emissiveStrength ?? 0,
                            pbrMaterial?.emissiveLightThreshold ?? -1
                        ),
                        textureFlags: Vector4(
                            hasTextureCoordinates && pbrMaterial?.baseColorTexture != nil ? 1 : 0,
                            hasTextureCoordinates && pbrMaterial?.metallicRoughnessTexture != nil ? 1 : 0,
                            hasTextureCoordinates && pbrMaterial?.normalTexture != nil ? 1 : 0,
                            hasTangents ? 1 : 0
                        ),
                        shadowFlags: Vector4(
                            mesh3d.receiveShadows ? 1 : 0,
                            atmosphereMaterial?.fresnelPower ?? 0,
                            atmosphereMaterial?.atmosphereIntensity ?? 0,
                            0
                        )
                    )
                )
                let key = Opaque3DBatchKey(
                    part: part,
                    material: material,
                    castShadows: mesh3d.castShadows,
                    receiveShadows: mesh3d.receiveShadows
                )

                if key == currentBatchKey, let currentBatchIndex {
                    let lowerBound = items[currentBatchIndex].batchRange?.lowerBound ?? instanceIndex
                    items[currentBatchIndex].batchRange = lowerBound..<(instanceIndex + 1)
                    continue
                }

                currentBatchKey = key
                currentBatchIndex = items.count
                items.append(
                    Opaque3DRenderItem(
                        entity: entity.id,
                        drawPass: drawPass.wrappedValue,
                        sortKey: 0,
                        modelIndex: modelIndex,
                        partIndex: partIndex,
                        mesh: mesh,
                        material: material,
                        worldTransform: transform.matrix,
                        castShadows: mesh3d.castShadows,
                        receiveShadows: mesh3d.receiveShadows,
                        batchRange: instanceIndex..<(instanceIndex + 1)
                    )
                )
            }
        }
    }

    instances.write(to: renderDevice.renderDevice)
    instanceBuffers.wrappedValue = instances
    renderItems.items = items
}

public final class Model3DDrawPass: DrawPass, @unchecked Sendable {
    private static let flatNormalTexture = Texture2D(
        image: Image(width: 1, height: 1, color: Color(red: 0.5, green: 0.5, blue: 1))
    )
    private static let blackTexture = Texture2D(
        image: Image(width: 1, height: 1, color: .black)
    )

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view _: Entity,
        item: Opaque3DRenderItem
    ) throws {
        let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
        let renderDevice = world.getResource(RenderDeviceHandler.self)?.renderDevice
        guard let renderDevice else {
            return
        }

        let pipelines = world.getRefResource(RenderPipelines<Flat3DPipeline>.self)
        let pipeline = pipelines.wrappedValue.pipeline(for: part.vertexDescriptor, device: renderDevice)
        guard
            let batchRange = item.batchRange,
            let instanceBuffers = world.getResource(Opaque3DInstanceBuffers.self),
            let instances = instanceBuffers.currentBuffer,
            let defaultVertexData = instanceBuffers.defaultVertexBuffer
        else {
            return
        }

        let pbrMaterial = item.material as? PBRMaterial
        let baseColorTexture = pbrMaterial?.baseColorTexture ?? Texture2D.whiteTexture
        let metallicRoughnessTexture = pbrMaterial?.metallicRoughnessTexture ?? Texture2D.whiteTexture
        let normalTexture = pbrMaterial?.normalTexture ?? Self.flatNormalTexture
        let emissiveTexture = pbrMaterial?.emissiveTexture ?? Self.blackTexture

        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setResourceSet(
            RenderResourceSet(
                bindings: [
                    .init(binding: 4, shaderStages: .fragment, resource: .texture(baseColorTexture)),
                    .init(binding: 5, shaderStages: .fragment, resource: .texture(metallicRoughnessTexture)),
                    .init(binding: 6, shaderStages: .fragment, resource: .texture(normalTexture)),
                    .init(binding: 7, shaderStages: .fragment, resource: .sampler(baseColorTexture.sampler)),
                    .init(binding: 8, shaderStages: .fragment, resource: .sampler(metallicRoughnessTexture.sampler)),
                    .init(binding: 9, shaderStages: .fragment, resource: .sampler(normalTexture.sampler)),
                    .init(binding: 12, shaderStages: .fragment, resource: .texture(emissiveTexture)),
                    .init(binding: 13, shaderStages: .fragment, resource: .sampler(emissiveTexture.sampler)),
                ]
            ),
            index: 0
        )
        renderEncoder.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
        renderEncoder.setVertexBuffer(
            instances,
            offset: Int(batchRange.lowerBound) * MemoryLayout<Flat3DInstanceData>.stride,
            slot: 3
        )
        renderEncoder.setVertexBuffer(defaultVertexData, offset: 0, slot: 4)
        renderEncoder.setIndexBuffer(part.indexBuffer, offset: 0)
        renderEncoder.drawIndexed(
            indexCount: part.indexCount,
            indexBufferOffset: 0,
            instanceCount: Int(batchRange.count)
        )
    }
}

private struct Opaque3DBatchKey: Equatable {
    let vertexBuffer: ObjectIdentifier
    let indexBuffer: ObjectIdentifier
    let material: ObjectIdentifier
    let castShadows: Bool
    let receiveShadows: Bool

    init(part: Mesh.Part, material: Material, castShadows: Bool, receiveShadows: Bool) {
        self.vertexBuffer = ObjectIdentifier(part.vertexBuffer)
        self.indexBuffer = ObjectIdentifier(part.indexBuffer)
        self.material = ObjectIdentifier(material)
        self.castShadows = castShadows
        self.receiveShadows = receiveShadows
    }
}
