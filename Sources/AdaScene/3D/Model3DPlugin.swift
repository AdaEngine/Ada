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
        // Model markers also work when hosts compose this plugin without DefaultPlugins.
        if !app.main.supportsEventDelivery {
            app.insertResource(HandledEvents())
            app.addSystem(EventsUpdateSystem.self, on: .preUpdate)
        }
        Model3DSource.registerComponent()
        Model3DSourceState.registerComponent()
        ModelAnimationPlayback3DComponent.registerComponent()
        app.addSystem(ModelAnimationPlayback3DSystem.self, on: .postUpdate)
        app.addSystem(Model3DSourceSystem.self, on: .preUpdate)
        Mesh3DComponent.registerComponent()
        Terrain3D.registerComponent()
        app.addSystem(Terrain3DSystem.self, on: .preUpdate)
        MeshLOD3DComponent.registerComponent()
        DirectionalLightComponent.registerComponent()
        PointLightComponent.registerComponent()
        SpotLightComponent.registerComponent()
        BillboardComponent.registerComponent()
        ParticleEmitter3D.registerComponent()
        app.addSystem(ParticleSimulation3DSystem.self, on: .postUpdate)
        ModelAnimation3DComponent.registerComponent()
        ModelNode3DComponent.registerComponent()
        SkinnedMesh3DComponent.registerComponent()
        MorphWeights3DComponent.registerComponent()
        app.addSystem(SkeletalAnimation3DSystem.self, on: .postUpdate)
        VoxelAnimationPlayback3DComponent.registerComponent()
        VoxelTransformAnimation3DComponent.registerComponent()
        VoxelShapeAnimation3DComponent.registerComponent()
        app.addSystem(VoxelAnimation3DSystem.self, on: .postUpdate)
        VoxelWorld3DComponent.registerComponent()
        VoxelChunk3DComponent.registerComponent()
        app.addSystem(VoxelWorldMeshing3DSystem.self, on: .preUpdate)

        app.addSystem(BillboardSystem.self, on: .update)

        guard let renderWorld = app.getSubworldBuilder(by: .renderWorld) else {
            return
        }

        renderWorld
            .insertResource(ExtractedLighting3D())
            .insertResource(ExtractedParticles3D())
            .addSystem(ExtractParticles3DSystem.self, on: .extract)
            .insertResource(ExtractedMesh3DSources())
            .insertResource(Model3DExtractionCache())
            .insertResource(AnimatedBounds3D())
            .insertResource(Active3DInstanceBuffers())
            .insertResource(Skinning3DUniforms())
            .insertResource(Morph3DUniforms())
            .insertResource(PBR3DUniforms())
            .insertResource(RenderPipelines(configurator: PBR3DPipeline()))
            .insertResource(RenderPipelines(configurator: Flat3DPipeline()))
            .insertResource(Model3DDrawPass())
            .addSystem(ExtractDirectionalLight3DSystem.self, on: .extract)
            .addSystem(ExtractModel3DSystem.self, on: .extract)
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
    _ morphs: Extract<Query<Entity,
    MorphWeights3DComponent>>,
    _ morphUniforms: ResMut<Morph3DUniforms>,
    _ sources: ResMut<ExtractedMesh3DSources>,
    _ animatedBounds: ResMut<AnimatedBounds3D>,
    _ skinningUniforms: ResMut<Skinning3DUniforms>,
    _ materialUniforms: ResMut<PBR3DUniforms>,
    _ renderDevice: Res<RenderDeviceHandler>,
    _ drawPass: Res<Model3DDrawPass>,
    _ cache: ResMut<Model3DExtractionCache>,
    _ mainWorld: Res<MainWorld?>,
    _ clock: Res<ShaderGraphClock?>
) {
    cache.wrappedValue.extract(
        sourceWorldID: mainWorld.wrappedValue?.world.id, elapsed: clock.wrappedValue?.elapsed ?? 0,
        query: query.wrappedValue, lods: lods.wrappedValue,
        visibility: visibilityAccess.wrappedValue, noCulling: noCullingAccess.wrappedValue, hierarchy: hierarchyAccess.wrappedValue,
        skins: skins.wrappedValue, morphs: morphs.wrappedValue,
        sources: &sources.wrappedValue, animatedBounds: &animatedBounds.wrappedValue,
        skinning: &skinningUniforms.wrappedValue, morphUniforms: &morphUniforms.wrappedValue,
        materials: &materialUniforms.wrappedValue, device: renderDevice.renderDevice, drawPass: drawPass.wrappedValue
    )
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

        let isMotion = world.getResource(ActiveMotion3DPass.self)?.isEnabled == true
        let isContact = world.getResource(ActiveContactDepth3DPass.self)?.isEnabled == true
        let morphed = item.morphBuffer != nil && part.morphTargets != nil
        let hasLightmapUV = part.vertexDescriptor.attributes.containsAttribute(by: MeshDescriptor.textureCoordinates1.id.name)
        let shadingFeatures = (item.material as? PBRMaterial)?.shaderFeatures ?? []
        let configuration = PBR3DConfiguration(
            vertex: part.vertexDescriptor,
            blended: (item.material as? PBRMaterial)?.effectiveAlphaMode == .blend,
            temporalDepth: view.components[RenderViewTarget.self]?.temporalUpscalingActive == true,
            // The motion shader has no shading layers, so its pipelines are not split by them.
            features: (isMotion || isContact ? [] : hasLightmapUV ? shadingFeatures : shadingFeatures.subtracting(.lightmap)).union(morphed ? .morph : [])
                .union(!isMotion && !isContact && view.components[RenderViewTarget.self]?.reflectionResponse3DTexture != nil ? .hybridReflection : [])
                .union(!isMotion && !isContact && view.components[RenderViewTarget.self]?.diffuseSurface3DTexture != nil ? .diffuseSurface : [])
                .union(!isMotion && !isContact && view.components[RenderViewTarget.self]?.irradianceGridActive == true ? .irradianceGrid : [])
        )
        var pipeline: any RenderPipeline
        if isContact {
            let pipelines = world.getRefResource(RenderPipelines<ContactDepth3DPipeline>.self)
            pipeline = pipelines.wrappedValue.pipeline(for: Shadow3DConfiguration(vertex: part.vertexDescriptor, morph: morphed), device: renderDevice)
        } else if isMotion {
            let pipelines = world.getRefResource(RenderPipelines<Motion3DPipeline>.self)
            pipeline = pipelines.wrappedValue.pipeline(for: configuration, device: renderDevice)
        } else {
            let pipelines = world.getRefResource(RenderPipelines<PBR3DPipeline>.self)
            pipeline = pipelines.wrappedValue.pipeline(for: configuration, device: renderDevice)
        }
        let usesGraph = (!isMotion && !isContact) || (item.material as? PBRMaterial)?.effectiveAlphaMode != .opaque
        if usesGraph, let graph = (item.material as? PBRMaterial)?.graphMaterial {
            do {
                pipeline = try ShaderGraph3DPipeline.make(
                    material: graph, base: pipeline, device: renderDevice,
                    variant: "pbr:\(isMotion):\(isContact):\(configuration.blended):\(configuration.temporalDepth):\(configuration.features.rawValue)",
                    features: configuration.features,
                    template: isContact ? "Shaders/directional_shadow_3d.glsl" : (isMotion ? "Shaders/motion_3d.glsl" : "Shaders/flat3d.glsl")
                )
            } catch {
                graph.reportCompilationError(error)
                return
            }
        }
        // Instance data of the view being drawn, written by VisibleMesh3DLists and activated by the render node.
        let active = world.getResource(Active3DInstanceBuffers.self)
        guard
            let batchRange = item.batchRange,
            let instances = active?.instances,
            let defaultVertexData = active?.defaults
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
        // The compact motion layout has no texture-presence attribute. Match the main
        // pass's alpha test when the material selects a UV set this part does not have.
        let baseUV = (pbrMaterial?.textureCoordinates.first ?? 0) == 1
            ? MeshDescriptor.textureCoordinates1.id.name : MeshDescriptor.textureCoordinates.id.name
        let motionHasBaseUV = part.vertexDescriptor.attributes.containsAttribute(by: baseUV)
        let baseColorTexture = isMotion && !motionHasBaseUV ? Texture2D.whiteTexture : (pbrMaterial?.baseColorTexture ?? Texture2D.whiteTexture)
        let metallicRoughnessTexture = pbrMaterial?.metallicRoughnessTexture ?? Texture2D.whiteTexture
        let normalTexture = pbrMaterial?.normalTexture ?? Self.flatNormalTexture
        let emissiveTexture = pbrMaterial?.emissiveTexture ?? Texture2D.whiteTexture
        let heightTexture = pbrMaterial?.heightTexture ?? Texture2D.whiteTexture
        // The main shader variant declares exactly the layer textures the material has (see PBRMaterial.shaderFeatures).
        var layerBindings: [RenderResourceSet.Binding] = []
        if morphed, let morphBuffer = item.morphBuffer, let morphSet = part.morphTargets {
            layerBindings.append(.init(binding: Morph3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(morphBuffer, offset: 0)))
            layerBindings.append(.init(binding: Morph3DUniforms.textureBinding, shaderStages: .vertex, resource: .texture(morphSet.deltaTexture)))
        }
        if !isMotion && !isContact, let pbrMaterial {
            if let map = pbrMaterial.lightmapTexture {
                layerBindings.append(.init(binding: 46, shaderStages: .fragment, resource: .texture(map)))
                layerBindings.append(.init(binding: 47, shaderStages: .fragment, resource: .sampler(map.sampler)))
            }
            let features = pbrMaterial.shaderFeatures
            for kind in PBRLayerTexture.allCases where features.contains(kind.feature) {
                if let layer = pbrMaterial.layerTextures[kind] {
                    layerBindings.append(.init(binding: kind.binding, shaderStages: .fragment, resource: .texture(layer.texture)))
                }
            }
        }

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
                    .init(binding: 17, shaderStages: .fragment, resource: .texture(heightTexture)),
                ] + layerBindings
            ),
            index: 0
        )
        renderEncoder.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
        if usesGraph, let graph = pbrMaterial?.graphMaterial {
            graph.bind(to: renderEncoder, device: renderDevice)
        }
        renderEncoder.setVertexBuffer(
            instances,
            offset: Int(batchRange.lowerBound) * MemoryLayout<Flat3DInstanceData>.stride,
            slot: 3
        )
        renderEncoder.setVertexBuffer(defaultVertexData, offset: 0, slot: 4)
        renderEncoder.setIndexBuffer(part.indexBuffer, offset: 0)
        if !isMotion && !isContact, let offset = item.indirectArgumentOffset, let arguments = active?.indirectArguments,
           renderEncoder.drawIndexedIndirect(arguments: arguments, offset: offset) { return }
        renderEncoder.drawIndexed(
            indexCount: part.indexCount,
            indexBufferOffset: 0,
            instanceCount: Int(batchRange.count)
        )
    }
}
