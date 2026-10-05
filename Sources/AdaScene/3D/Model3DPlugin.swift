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
        Model3DSource.registerComponent()
        Model3DSourceState.registerComponent()
        app.addSystem(Model3DSourceSystem.self, on: .preUpdate)
        Mesh3DComponent.registerComponent()
        MeshLOD3DComponent.registerComponent()
        DirectionalLightComponent.registerComponent()
        PointLightComponent.registerComponent()
        SpotLightComponent.registerComponent()
        BillboardComponent.registerComponent()
        ModelAnimation3DComponent.registerComponent()
        ModelNode3DComponent.registerComponent()
        SkinnedMesh3DComponent.registerComponent()
        app.addSystem(SkeletalAnimation3DSystem.self, on: .postUpdate)

        app.addSystem(BillboardSystem.self, on: .update)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        renderWorld
            .insertResource(ExtractedLighting3D())
            .insertResource(ExtractedMesh3DSources())
            .insertResource(AnimatedBounds3D())
            .insertResource(Active3DInstanceBuffers())
            .insertResource(RenderItems<Opaque3DRenderItem>())
            .insertResource(Opaque3DInstanceBuffers())
            .insertResource(Skinning3DUniforms())
            .insertResource(PBR3DUniforms())
            .insertResource(RenderPipelines(configurator: PBR3DPipeline()))
            .insertResource(RenderPipelines(configurator: Flat3DPipeline()))
            .insertResource(Model3DDrawPass())
            .addSystem(ExtractDirectionalLight3DSystem.self, on: .extract)
            .addSystem(ExtractModel3DSystem.self, on: .extract)
    }
}

@System
func ExtractDirectionalLight3D(
    _ query: Extract<Query<Entity,
    DirectionalLightComponent,
    GlobalTransform>>,
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
    _ query: Extract<Query<Entity,
    Mesh3DComponent,
    GlobalTransform>>,
    _ lods: Extract<Query<Entity,
    MeshLOD3DComponent>>,
    _ visibilityAccess: Extract<Query<Entity,
    Visibility>>,
    _ noCullingAccess: Extract<Query<Entity,
    NoFrustumCulling>>,
    _ hierarchyAccess: Extract<Query<Entity,
    RelationshipComponent>>,
    _ skins: Extract<Query<Entity,
    SkinnedMesh3DComponent>>,
    _ sources: ResMut<ExtractedMesh3DSources>,
    _ animatedBounds: ResMut<AnimatedBounds3D>,
    _ skinningUniforms: ResMut<Skinning3DUniforms>,
    _ materialUniforms: ResMut<PBR3DUniforms>,
    _ renderItems: ResMut<RenderItems<Opaque3DRenderItem>>,
    _ instanceBuffers: ResMut<Opaque3DInstanceBuffers>,
    _ renderDevice: Res<RenderDeviceHandler>,
    _ drawPass: Res<Model3DDrawPass>
) {
    animatedBounds.wrappedValue.beginFrame()
    var previousTransforms: [Entity.ID: Transform3D] = [:]
    for source in sources.meshes { previousTransforms[source.entity] = source.transform }
    sources.meshes.removeAll(keepingCapacity: true)
    // These typed queries declare all optional/hierarchical component reads without requiring them on a mesh.
    _ = visibilityAccess.wrappedValue
    _ = noCullingAccess.wrappedValue
    _ = hierarchyAccess.wrappedValue
    var lodByEntity: [Entity.ID: MeshLOD3DComponent] = [:]
    lods.wrappedValue.forEach { entity, lod in lodByEntity[entity.id] = lod }
    var posedBounds: [Entity.ID: AABB] = [:]
    var items = renderItems.items
    items.removeAll(keepingCapacity: true)
    var instances = instanceBuffers.wrappedValue
    instances.beginFrame()
    skinningUniforms.wrappedValue.beginFrame(device: renderDevice.renderDevice)
    skins.wrappedValue.forEach { entity, skin in
        _ = skinningUniforms.wrappedValue.write(skin.matrices, for: entity.id, device: renderDevice.renderDevice)
        if let mesh = entity.components[Mesh3DComponent.self]?.mesh {
            posedBounds[entity.id] = animatedBounds.wrappedValue.bounds(mesh: mesh, matrices: skin.matrices)
        }
    }
    materialUniforms.wrappedValue.beginFrame()
    var currentBatchKey: Opaque3DBatchKey?
    var currentBatchIndex: Int?

    query.wrappedValue.forEach { entity, mesh3d, transform in
        let lod = lodByEntity[entity.id]
        let visibility = entity.components[Visibility.self]
        let noCulling = entity.components[NoFrustumCulling.self]
        if visibility == .hidden {
            return
        }
        var ancestor = entity.parent
        while let parent = ancestor {
            if parent.components[Visibility.self] == .hidden {
                return
            }
            ancestor = parent.parent
        }
        let mesh = mesh3d.mesh
        let palette = skinningUniforms.wrappedValue.buffer(for: entity.id)
        var localBounds: AABB? = palette == nil ? mesh.bounds : posedBounds[entity.id]
        if palette == nil, let lod {
            for level in lod.alternatives { localBounds = localBounds.map { AABB(min: min($0.min, level.bounds.min), max: max($0.max, level.bounds.max)) } ?? level.bounds }
        }
        sources.meshes.append(Mesh3DRenderSource(
            entity: entity.id,
            drawPass: drawPass.wrappedValue,
            mesh: mesh,
            materials: mesh3d.materials,
            transform: transform.matrix,
            bounds: localBounds.map { MeshVisibility3DMath.transformed($0, by: transform.matrix) },
            alternatives: palette == nil ? lod?.alternatives ?? [] : [],
            thresholds: lod?.screenThresholds ?? [],
            hysteresis: lod?.hysteresis ?? 0.15,
            maximumDistance: lod?.maximumDistance,
            fadeDistance: lod?.fadeDistance ?? 4,
            forceVisible: noCulling != nil,
            castShadows: mesh3d.castShadows,
            receiveShadows: mesh3d.receiveShadows,
            skinningBuffer: palette,
            previousTransform: previousTransforms[entity.id]
        ))
        for (modelIndex, model) in mesh.models.enumerated() {
            for (partIndex, part) in model.parts.enumerated() {
                let material = mesh3d.materials[part.materialIndex]
                materialUniforms.wrappedValue.write(material: material, descriptor: part.vertexDescriptor, device: renderDevice.renderDevice)
                let pbrMaterial = material as? PBRMaterial
                let atmosphereMaterial = material as? AtmosphereMaterial
                func hasUV(_ slot: Int) -> Bool {
                    let set = pbrMaterial?.textureCoordinates.indices.contains(slot) == true ? pbrMaterial?.textureCoordinates[slot] ?? 0 : 0
                    let name = set == 1 ? MeshDescriptor.textureCoordinates1.id.name : MeshDescriptor.textureCoordinates.id.name
                    return part.vertexDescriptor.attributes.containsAttribute(by: name)
                }
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
                            pbrMaterial?.emissiveStrength ?? 0,
                            pbrMaterial?.emissiveLightThreshold ?? -1
                        ),
                        textureFlags: Vector4(
                            hasUV(0) && pbrMaterial?.baseColorTexture != nil ? 1 : 0,
                            hasUV(1) && pbrMaterial?.metallicRoughnessTexture != nil ? 1 : 0,
                            hasUV(2) && pbrMaterial?.normalTexture != nil ? 1 : 0,
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
                    receiveShadows: mesh3d.receiveShadows,
                    skinningBuffer: skinningUniforms.wrappedValue.buffer(for: entity.id)
                )

                if pbrMaterial?.alphaMode != .blend, key == currentBatchKey, let currentBatchIndex {
                    let lowerBound = items[currentBatchIndex].batchRange?.lowerBound ?? instanceIndex
                    items[currentBatchIndex].batchRange = lowerBound ..< (instanceIndex + 1)
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
                        batchRange: instanceIndex ..< (instanceIndex + 1),
                        skinningBuffer: skinningUniforms.wrappedValue.buffer(for: entity.id)
                    )
                )
            }
        }
    }

    animatedBounds.wrappedValue.finishFrame()
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
        view: Entity,
        item: Opaque3DRenderItem
    ) throws {
        let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
        let renderDevice = world.getResource(RenderDeviceHandler.self)?.renderDevice
        guard let renderDevice else {
            return
        }

        let configuration = PBR3DConfiguration(
            vertex: part.vertexDescriptor,
            blended: (item.material as? PBRMaterial)?.alphaMode == .blend,
            temporalDepth: view.components[RenderViewTarget.self]?.temporalUpscalingActive == true
        )
        let isMotion = world.getResource(ActiveMotion3DPass.self)?.isEnabled == true
        let pipeline: any RenderPipeline
        if isMotion {
            let pipelines = world.getRefResource(RenderPipelines<Motion3DPipeline>.self)
            pipeline = pipelines.wrappedValue.pipeline(for: configuration, device: renderDevice)
        } else {
            let pipelines = world.getRefResource(RenderPipelines<PBR3DPipeline>.self)
            pipeline = pipelines.wrappedValue.pipeline(for: configuration, device: renderDevice)
        }
        let active = world.getResource(Active3DInstanceBuffers.self)
        let instanceBuffers = world.getResource(Opaque3DInstanceBuffers.self)
        guard
            let batchRange = item.batchRange,
            let instances = active?.instances ?? instanceBuffers?.currentBuffer,
            let defaultVertexData = active?.defaults ?? instanceBuffers?.defaultVertexBuffer
        else {
            return
        }

        guard let palette = item.skinningBuffer ?? world.getResource(Skinning3DUniforms.self)?.identityBuffer else {
            return
        }
        guard let materialBuffer = world.getResource(PBR3DUniforms.self)?.buffer(for: item.material) else {
            return
        }
        let pbrMaterial = item.material as? PBRMaterial
        let baseColorTexture = pbrMaterial?.baseColorTexture ?? Texture2D.whiteTexture
        let metallicRoughnessTexture = pbrMaterial?.metallicRoughnessTexture ?? Texture2D.whiteTexture
        let normalTexture = pbrMaterial?.normalTexture ?? Self.flatNormalTexture
        let emissiveTexture = pbrMaterial?.emissiveTexture ?? Texture2D.whiteTexture

        if isMotion {
            let previous = world.getResource(Skinning3DUniforms.self)?.previousBuffer(for: item.entity) ?? palette
            renderEncoder.setResourceSet(RenderResourceSet(bindings: [
                .init(binding: 24, shaderStages: .vertex, resource: .uniformBuffer(previous, offset: 0)),
            ]), index: 0)
        }
        renderEncoder.setRenderPipelineState(pipeline)
        renderEncoder.setResourceSet(
            RenderResourceSet(
                bindings: [
                    .init(binding: PBR3DUniforms.binding, shaderStages: .fragment, resource: .uniformBuffer(materialBuffer, offset: 0)),
                    .init(binding: 16, shaderStages: .fragment, resource: .texture(pbrMaterial?.occlusionTexture ?? Texture2D.whiteTexture)),
                    .init(binding: 0, shaderStages: .fragment, resource: .sampler((pbrMaterial?.occlusionTexture ?? Texture2D.whiteTexture).sampler)),
                    .init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(palette, offset: 0)),
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
    let skinningBuffer: ObjectIdentifier?

    init(part: Mesh.Part, material: Material, castShadows: Bool, receiveShadows: Bool, skinningBuffer: (any UniformBuffer)?) {
        vertexBuffer = ObjectIdentifier(part.vertexBuffer)
        indexBuffer = ObjectIdentifier(part.indexBuffer)
        self.material = ObjectIdentifier(material)
        self.castShadows = castShadows
        self.receiveShadows = receiveShadows
        self.skinningBuffer = skinningBuffer.map { ObjectIdentifier($0) }
    }
}
