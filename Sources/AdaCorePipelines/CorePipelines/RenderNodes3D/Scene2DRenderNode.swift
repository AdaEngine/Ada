import AdaECS
@_spi(Internal) import AdaRender

/// Draws transparent 2D content over the composited scene, testing against mesh depth.
public struct Scene2DRenderNode: RenderNode {
    public static let name: RenderNodeLabel = "Main3D.Scene2D"

    @Res<SortedRenderItems<Transparent2DRenderItem>>
    private var renderItems

    @ResMut<Scene2DPipelines>
    private var pipelines

    @Res<RenderDeviceHandler>
    private var device

    public init() {}

    public func update(from world: World) {
        _renderItems.update(from: world)
        _pipelines.update(from: world)
        _device.update(from: world)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard
            let view = context.viewEntity,
            let camera = view.components[Camera.self],
            let uniform = view.components[GlobalViewUniform.self],
            let target = view.components[RenderViewTarget.self],
            let color = target.mainTexture,
            let depth = target.depthTexture
        else {
            return []
        }

        let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
        commandBuffer.label = "Scene 2D Render Pass"
        let pass = commandBuffer.beginRenderPass(
            RenderPassDescriptor(
                label: "Scene 2D Render Pass",
                colorAttachments: [
                    .init(
                        texture: color,
                        operation: OperationDescriptor(loadAction: .load, storeAction: .store)
                    )
                ],
                depthStencilAttachment: .init(
                    texture: depth,
                    depthOperation: OperationDescriptor(loadAction: .load, storeAction: .store),
                    stencilOperation: OperationDescriptor(loadAction: .load, storeAction: .store)
                )
            )
        )
        pass.setVertexBuffer(uniform, slot: GlobalBufferIndex.viewUniform)
        pass.setViewport(camera.viewport.rect)

        for var item in renderItems.items.items {
            item.renderPipeline = pipelines.pipeline(for: item.renderPipeline, device: device.renderDevice)
            try AnyDrawPass(item.drawPass).render(with: pass, world: context.world, view: view, item: item)
        }

        pass.endRenderPass()
        if let output = target.outputTexture, color === output {
            commandBuffer.addCompletedHandler { [output] in output.notifyRenderCompleted() }
        }
        commandBuffer.commit()
        return []
    }
}

/// Keeps scene variants separate from the pipelines used by ordinary 2D cameras.
struct Scene2DPipelines: Resource {
    struct Entry: Sendable {
        let source: RenderPipeline
        let scene: RenderPipeline
    }

    private var entries: [ObjectIdentifier: Entry] = [:]

    mutating func pipeline(for source: RenderPipeline, device: RenderDevice) -> RenderPipeline {
        let key = ObjectIdentifier(source)
        if let entry = entries[key] {
            return entry.scene
        }
        var descriptor = source.descriptor
        descriptor.debugName += " (Scene 2D)"
        descriptor.backfaceCulling = false
        descriptor.depthPixelFormat = .depth_32f_stencil8
        descriptor.depthStencilDescriptor = DepthStencilDescriptor(
            isDepthTestEnabled: true,
            isDepthWriteEnabled: false,
            depthCompareOperator: .lessOrEqual
        )
        let pipeline = device.createRenderPipeline(from: descriptor)
        entries[key] = Entry(source: source, scene: pipeline)
        return pipeline
    }
}
