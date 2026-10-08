//
//  Main2DRenderNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 26.11.2025.
//

import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// This render node responsible for rendering ``Transparent2DRenderItem``.
public struct Main2DRenderNode: RenderNode {
    /// Input slots of render node.
    public enum InputNode {
        public static let view: RenderSlot.Label = "view"
    }

    @Query<
        Entity,
        Camera,
        RenderViewTarget,
        GlobalViewUniform
    >
    private var query

    @Res<SortedRenderItems<Transparent2DRenderItem>>
    private var renderItems

    public init() {}

    public let inputResources: [RenderSlot] = [
        RenderSlot(name: InputNode.view, kind: .entity)
    ]

    public func update(from world: World) {
        query.update(from: world)
        _renderItems.update(from: world)
    }

    public func execute(context: inout Context, renderContext: RenderContext) async throws -> [RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }

        try query.forEach { entity, camera, target, uniform in
            if entity != view {
                return
            }

            let clearColor = camera.clearFlags.contains(.solid) ? camera.backgroundColor : .surfaceClearColor
            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "Main 2d Render Pass"
            guard let mainTex = target.mainTexture else {
                return
            }
            let texture: Texture =
                if target.lighting2DUsesDeferredTargets, let scene = target.sceneColorTexture {
                    scene
                } else {
                    mainTex
                }

            let renderPass = commandBuffer.beginRenderPass(
                RenderPassDescriptor(
                    label: "Main 2d Render Pass",
                    colorAttachments: [
                        .init(
                            texture: texture,
                            operation: OperationDescriptor(
                                loadAction: .clear,
                                storeAction: .store
                            ),
                            clearColor: clearColor
                        )
                    ],
                    depthStencilAttachment: nil
                )
            )

            renderPass.setVertexBuffer(uniform, slot: GlobalBufferIndex.viewUniform)
            renderPass.setViewport(camera.viewport.rect)

            if !renderItems.items.items.isEmpty {
                try renderItems.items.render(with: renderPass, world: context.world, view: view)
            }

            renderPass.endRenderPass()
            if let outputTexture = target.outputTexture,
                texture === outputTexture {
                commandBuffer.addCompletedHandler { [outputTexture] in
                    outputTexture.notifyRenderCompleted()
                }
            }
            commandBuffer.commit()
        }

        return []
    }
}

/// An object describe 2D render item.
public struct Transparent2DRenderItem: RenderItem {
    /// An entity that hold additional information about render item.
    public var entity: Entity.ID

    /// Draw pass which will be used for rendering this item.
    public var drawPass: any DrawPass

    /// Render Pipeline for rendering this item.
    public var renderPipeline: RenderPipeline

    /// Sort key used for rendering order.
    public var sortKey: Float

    /// If item support batch rendering, pass range of indecies.
    public var batchRange: Range<Int32>?

    public init(
        entity: Entity.ID,
        drawPass: any DrawPass,
        renderPipeline: RenderPipeline,
        sortKey: Float,
        batchRange: Range<Int32>? = nil
    ) {
        self.entity = entity
        self.drawPass = drawPass
        self.renderPipeline = renderPipeline
        self.sortKey = sortKey
        self.batchRange = batchRange
    }
}
