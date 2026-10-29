import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math
import Tracing

/// Math used to position the primary directional shadow map around the active camera.
public enum DirectionalShadow3DMath {
    public static func makeViewProjection(
        cameraViewMatrix: Transform3D,
        directionToLight: Vector3,
        shadowDistance: Float,
        shadowMapResolution: Int = DirectionalShadow3D.resolution
    ) -> Transform3D {
        let distance = max(1, shadowDistance)
        let inverseView = cameraViewMatrix.inverse
        let cameraPosition = inverseView.w.xyz
        let cameraForward = inverseView.z.xyz.normalized
        let center = cameraPosition + cameraForward * (distance * 0.5)
        let rayDirection = -directionToLight.normalized
        let up: Vector3 = Swift.abs(rayDirection.dot(.up)) > 0.95 ? .right : .up
        let right = up.cross(rayDirection).normalized
        let viewUp = rayDirection.cross(right)
        let halfExtent = distance * 0.5
        let resolution = Float(max(1, shadowMapResolution))
        let worldUnitsPerTexel = halfExtent * 2 / resolution
        let centerRight = center.dot(right)
        let centerUp = center.dot(viewUp)
        let snappedRight = (centerRight / worldUnitsPerTexel).rounded() * worldUnitsPerTexel
        let snappedUp = (centerUp / worldUnitsPerTexel).rounded() * worldUnitsPerTexel
        let stabilizedCenter =
            center
                + right * (snappedRight - centerRight)
                + viewUp * (snappedUp - centerUp)
        let eye = stabilizedCenter - rayDirection * distance
        let view = Transform3D(
            [right.x, viewUp.x, rayDirection.x, 0],
            [right.y, viewUp.y, rayDirection.y, 0],
            [right.z, viewUp.z, rayDirection.z, 0],
            [-right.dot(eye), -viewUp.dot(eye), -rayDirection.dot(eye), 1]
        )
        let projection = Transform3D.orthographic(
            left: -halfExtent,
            right: halfExtent,
            top: halfExtent,
            bottom: -halfExtent,
            zNear: 0.1,
            zFar: distance * 2
        )
        return projection * view
    }
}

/// Renders opaque 3D instances from the primary directional light before the main PBR pass.
public struct DirectionalShadow3DRenderNode: RenderNode {
    @Query<Entity, Camera, GlobalViewUniform, ExtractedCameraSource>
    private var query

    @ResMut<VisibleMesh3DLists> private var lists
    @Res<Render3DVisibilityStatistics> private var statistics

    @Res<ExtractedEnvironment3D> private var environments

    @Res<ExtractedLighting3D>
    private var lighting

    @ResMut<PBR3DUniforms>
    private var materialUniforms

    @Res<Skinning3DUniforms>
    private var skinningUniforms

    @ResMut<DirectionalShadow3D>
    private var shadow

    @ResMut<DirectionalShadow3DScratch>
    private var scratch

    @ResMut<RenderPipelines<DirectionalShadow3DPipeline>>
    private var pipelines

    @Res<RenderDeviceHandler>
    private var renderDevice

    @Res<Render3DPerformanceMetrics?> private var metrics

    public init() {}

    public func update(from world: World) {
        _metrics.update(from: world)
        query.update(from: world)
        _lighting.update(from: world)
        _environments.update(from: world)
        _lists.update(from: world)
        _statistics.update(from: world)
        _skinningUniforms.update(from: world)
        _materialUniforms.update(from: world)
        _shadow.update(from: world)
        _scratch.update(from: world)
        _pipelines.update(from: world)
        _renderDevice.update(from: world)
        var activeViews: [Entity.ID] = []
        query.forEach { _, _, _, source in activeViews.append(source.entityId) }
        scratch.cache.retainViews(activeViews)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity,
            let candidates = context.world.getResource(ExtractedMesh3DSources.self) else {
            return []
        }

        var submitted: CommandBuffer?
        query.forEach { entity, camera, viewUniform, source in
            guard entity == view else {
                return
            }
            for index in 0 ..< 3 { statistics.record(Visibility3DCount(), view: source.entityId, pass: index) }
            let settings = environments.environments[source.entityId]?.shadows ?? ShadowSettings3D()
            guard
                settings.isEnabled,
                let light = lighting.directionalLight,
                light.castsShadows,
                !candidates.meshes.isEmpty
            else {
                shadow.isEnabled = false
                return
            }

            let count = min(max(settings.cascadeCount, 1), 3)
            // Three horizontal tiles must fit WebGPU's guaranteed 8192-pixel limit.
            let tileResolution = min(max(settings.resolution, 256), count == 3 ? 2048 : 4096)
            prepareTexturesIfNeeded(count: count, resolution: tileResolution)
            guard
                let colorTexture = shadow.colorTexture,
                let depthTexture = shadow.depthTexture
            else {
                shadow.isEnabled = false
                return
            }

            let far = min(light.shadowDistance, camera.projection.far)
            let cascades: [ShadowCascade3D]
            if count == 1 {
                let matrix = DirectionalShadow3DMath.makeViewProjection(cameraViewMatrix: viewUniform.viewMatrix, directionToLight: light.directionToLight, shadowDistance: far, shadowMapResolution: tileResolution)
                cascades = [.init(viewProjection: matrix, farDepth: far, radius: far / 2, corners: [])]
            } else {
                cascades = DirectionalShadow3DMath.cascades(
                    view: viewUniform.viewMatrix,
                    projection: viewUniform.projectionMatrix,
                    near: camera.projection.near,
                    far: far,
                    directionToLight: light.directionToLight,
                    count: count,
                    lambda: settings.splitLambda,
                    blendFraction: settings.blendFraction,
                    resolution: tileResolution
                )
            }
            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Directional Shadow 3D Pass"
            let pass = commandBuffer.beginRenderPass(
                RenderPassDescriptor(
                    label: "Directional Shadow 3D Pass",
                    colorAttachments: [
                        .init(
                            texture: colorTexture,
                            operation: OperationDescriptor(loadAction: .clear, storeAction: .store),
                            clearColor: .white
                        ),
                    ],
                    depthStencilAttachment: DepthStencilAttachmentDescriptor(
                        texture: depthTexture,
                        depthOperation: OperationDescriptor(loadAction: .clear, storeAction: .dontCare),
                        stencilOperation: OperationDescriptor(loadAction: .clear, storeAction: .dontCare)
                    )
                )
            )
            let resolution = Float(tileResolution)
            for cascadeIndex in cascades.indices {
                pass.setViewport(Rect(x: Float(cascadeIndex) * resolution, y: 0, width: resolution, height: resolution))
                let preparationSpan = AdaTrace.startSpan("Render3D.ShadowPrepare")
                lists.prepare(
                    sources: candidates.meshes,
                    view: source.entityId,
                    pass: cascadeIndex,
                    viewMatrix: viewUniform.viewMatrix,
                    projection: viewUniform.projectionMatrix,
                    cullingProjection: cascades[cascadeIndex].viewProjection,
                    settings: environments.environments[source.entityId]?.meshVisibility ?? MeshVisibilitySettings3D(),
                    device: renderDevice.renderDevice,
                    materials: &_materialUniforms.wrappedValue
                )
                preparationSpan.end()
                let visibleItems = lists.items(view: source.entityId, pass: cascadeIndex)
                let buffers = lists.buffers(view: source.entityId, pass: cascadeIndex)
                statistics.record(lists.count(view: source.entityId, pass: cascadeIndex), view: source.entityId, pass: cascadeIndex)
                guard let instances = buffers.instances else { continue }
                let constants = scratch.cache.write(
                    DirectionalShadowViewUniform(
                        viewProjection: cascades[cascadeIndex].viewProjection,
                        tileBounds: Vector4(Float(cascadeIndex) * resolution, 0, Float(cascadeIndex + 1) * resolution, resolution)
                    ),
                    view: source.entityId,
                    pass: cascadeIndex,
                    device: renderDevice.renderDevice
                )
                pass.setVertexBuffer(constants, offset: 0, slot: GlobalBufferIndex.viewUniform)

                let encodingSpan = AdaTrace.startSpan("Render3D.ShadowEncode")
                for item in visibleItems {
                    let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
                    guard item.castShadows, (item.material as? PBRMaterial)?.effectiveAlphaMode != .blend, let batchRange = item.batchRange else {
                        continue
                    }
                    let morphed = item.morphBuffer != nil && part.morphTargets != nil
                    let pipeline = pipelines.pipeline(for: Shadow3DConfiguration(vertex: part.vertexDescriptor, morph: morphed), device: renderDevice.renderDevice)
                    guard ShaderGraph3DPipeline.bindShadow(encoder: pass, base: pipeline, material: item.material, device: renderDevice.renderDevice, morph: morphed) else { continue }
                    pass.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
                    if let material = materialUniforms.buffer(for: item.material) {
                        let base = (item.material as? PBRMaterial)?.baseColorTexture ?? Texture2D.whiteTexture
                        pass.setResourceSet(RenderResourceSet(bindings: [
                            .init(binding: 15, shaderStages: .fragment, resource: .uniformBuffer(material, offset: 0)),
                            .init(binding: 4, shaderStages: .fragment, resource: .texture(base)),
                            .init(binding: 7, shaderStages: .fragment, resource: .sampler(base.sampler)),
                        ]), index: 0)
                    }
                    if let palette = item.skinningBuffer ?? skinningUniforms.identityBuffer {
                        pass.setResourceSet(RenderResourceSet(bindings: [
                            .init(binding: Skinning3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(palette, offset: 0)),
                        ]), index: 0)
                    }
                    if morphed, let morphBuffer = item.morphBuffer, let morphSet = part.morphTargets {
                        pass.setResourceSet(RenderResourceSet(bindings: [
                            .init(binding: Morph3DUniforms.binding, shaderStages: .vertex, resource: .uniformBuffer(morphBuffer, offset: 0)),
                            .init(binding: Morph3DUniforms.textureBinding, shaderStages: .vertex, resource: .texture(morphSet.deltaTexture)),
                        ]), index: 0)
                    }
                    if let defaults = buffers.defaults {
                        pass.setVertexBuffer(defaults, offset: 0, slot: 4)
                    }
                    pass.setVertexBuffer(
                        instances,
                        offset: Int(batchRange.lowerBound) * MemoryLayout<Flat3DInstanceData>.stride,
                        slot: 3
                    )
                    pass.setIndexBuffer(part.indexBuffer, offset: 0)
                    pass.drawIndexed(
                        indexCount: part.indexCount,
                        indexBufferOffset: 0,
                        instanceCount: Int(batchRange.count)
                    )
                }
                encodingSpan.end()
            }
            pass.endRenderPass()
            if let metrics {
                commandBuffer.addCompletedTimingHandler { metrics.record(pass: "shadows", seconds: $0) }
            }
            submitted = commandBuffer
            shadow.viewProjection = cascades[0].viewProjection
            shadow.viewProjection1 = cascades.count > 1 ? cascades[1].viewProjection : .identity
            shadow.viewProjection2 = cascades.count > 2 ? cascades[2].viewProjection : .identity
            shadow.cascadeSplits = Vector4(cascades[0].farDepth, cascades.count > 1 ? cascades[1].farDepth : far, far, Float(count))
            shadow.blendFraction = finiteRenderValue(settings.blendFraction, fallback: 0.1, range: 0 ... 0.25)
            shadow.isEnabled = true
        }

        if let submitted {
            if let metrics { await metrics.commit(submitted) } else { submitted.commit() }
        }
        return []
    }

    private func prepareTexturesIfNeeded(count: Int, resolution: Int) {
        let size = SizeInt(
            width: resolution * count,
            height: resolution
        )
        if shadow.colorTexture?.size != size {
            shadow.colorTexture = RenderTexture(
                size: size,
                scaleFactor: 1,
                format: .rgba_32f,
                debugLabel: "Directional Shadow 3D Map",
                samplerDescription: SamplerDescriptor(
                    minFilter: .nearest,
                    magFilter: .nearest,
                    mipFilter: .notMipmapped
                )
            )
        }
        if shadow.depthTexture?.size != size {
            shadow.depthTexture = RenderTexture(
                size: size,
                scaleFactor: 1,
                format: .depth_32f_stencil8,
                debugLabel: "Directional Shadow 3D Depth"
            )
        }
    }
}
