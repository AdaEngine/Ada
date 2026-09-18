import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

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
    @Query<Entity, Camera, GlobalViewUniform>
    private var query

    @Res<RenderItems<Opaque3DRenderItem>>
    private var renderItems

    @Res<ExtractedLighting3D>
    private var lighting

    @Res<Opaque3DInstanceBuffers>
    private var instanceBuffers

    @ResMut<DirectionalShadow3D>
    private var shadow

    @ResMut<DirectionalShadow3DScratch>
    private var scratch

    @ResMut<RenderPipelines<DirectionalShadow3DPipeline>>
    private var pipelines

    @Res<RenderDeviceHandler>
    private var renderDevice

    public init() {}

    public func update(from world: World) {
        query.update(from: world)
        _renderItems.update(from: world)
        _lighting.update(from: world)
        _instanceBuffers.update(from: world)
        _shadow.update(from: world)
        _scratch.update(from: world)
        _pipelines.update(from: world)
        _renderDevice.update(from: world)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }

        query.forEach { entity, _, viewUniform in
            guard entity == view else {
                return
            }
            guard
                let light = lighting.directionalLight,
                light.castsShadows,
                !renderItems.items.isEmpty,
                let instances = instanceBuffers.currentBuffer
            else {
                shadow.isEnabled = false
                return
            }

            prepareTexturesIfNeeded()
            guard
                let colorTexture = shadow.colorTexture,
                let depthTexture = shadow.depthTexture
            else {
                shadow.isEnabled = false
                return
            }

            let viewProjection = DirectionalShadow3DMath.makeViewProjection(
                cameraViewMatrix: viewUniform.viewMatrix,
                directionToLight: light.directionToLight,
                shadowDistance: light.shadowDistance
            )
            scratch.view.elements = [DirectionalShadowViewUniform(viewProjection: viewProjection)]
            scratch.view.write(to: renderDevice.renderDevice)

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
                        )
                    ],
                    depthStencilAttachment: DepthStencilAttachmentDescriptor(
                        texture: depthTexture,
                        depthOperation: OperationDescriptor(loadAction: .clear, storeAction: .dontCare),
                        stencilOperation: OperationDescriptor(loadAction: .clear, storeAction: .dontCare)
                    )
                )
            )
            let resolution = Float(DirectionalShadow3D.resolution)
            pass.setViewport(Rect(x: 0, y: 0, width: resolution, height: resolution))
            pass.setVertexBuffer(scratch.view, offset: 0, slot: GlobalBufferIndex.viewUniform)

            for item in renderItems.items {
                let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
                guard item.castShadows, let batchRange = item.batchRange else {
                    continue
                }
                let pipeline = pipelines.pipeline(for: part.vertexDescriptor, device: renderDevice.renderDevice)
                pass.setRenderPipelineState(pipeline)
                pass.setVertexBuffer(part.vertexBuffer, offset: 0, slot: 0)
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

            pass.endRenderPass()
            commandBuffer.commit()
            shadow.viewProjection = viewProjection
            shadow.isEnabled = true
        }

        return []
    }

    private func prepareTexturesIfNeeded() {
        let size = SizeInt(
            width: DirectionalShadow3D.resolution,
            height: DirectionalShadow3D.resolution
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
