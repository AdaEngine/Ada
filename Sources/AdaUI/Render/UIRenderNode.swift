//
//  UIRenderNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 19.12.2025.
//

import AdaECS
import AdaRender
import AdaUtils
import Math

// TODO: - Avoid redrawing if nothing changed.

/// Resource that holds the UI view uniform for rendering.
/// Uses an orthographic projection with origin at top-left corner.
public struct UIViewUniform: Resource {
    public var viewProjectionMatrix: Transform3D = .identity

    public init() {}
}

public struct UIRenderNode: RenderNode {
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

    @Res<RenderItems<UITransparentRenderItem>>
    private var renderItems

    @Res<PrimaryWindowId>
    private var primaryWindowId

    @ResMut<UIViewUniform>
    private var uiViewUniform

    @Res<RenderDeviceHandler>
    private var renderDevice

    @ResMut<GlassBackgroundTexture>
    private var glassBackground

    public init() {}

    public let inputResources: [RenderSlot] = [
        RenderSlot(name: InputNode.view, kind: .entity)
    ]

    public func update(from world: World) {
        query.update(from: world)
        _renderItems.update(from: world)
        _primaryWindowId.update(from: world)
        _uiViewUniform.update(from: world)
        _renderDevice.update(from: world)
        _glassBackground.update(from: world)
    }

    public func execute(
        context: inout Context,
        renderContext: AdaRender.RenderContext
    ) async throws -> [AdaRender.RenderSlotValue] {
        guard let view = context.viewEntity else {
            return []
        }

        try query.forEach { entity, camera, target, _ in
            if entity != view {
                return
            }

            guard let texture = target.mainTexture else {
                return
            }
            let targetWindowId = camera.targetWindowId(from: primaryWindowId)

            let texWidth = texture.width
            let texHeight = texture.height

            // Snapshot main target for glass (must complete before glass fragments sample it).
            if glassBackground.texture == nil
                || glassBackground.texture?.width != texWidth
                || glassBackground.texture?.height != texHeight {
                glassBackground.texture = RenderTexture(
                    size: SizeInt(width: texWidth, height: texHeight),
                    scaleFactor: texture.scaleFactor,
                    format: .bgra8,
                    debugLabel: "GlassBackground",
                    samplerDescription: SamplerDescriptor(
                        minFilter: .linear,
                        magFilter: .linear,
                        mipFilter: .notMipmapped
                    )
                )
            }

            let commandBuffer = renderContext.commandQueue.makeCommandBuffer()
            commandBuffer.label = "UI Render + Glass Capture"

            // Get viewport size
            let viewportSize = camera.viewport.rect.size
            let logicalViewportSize = camera.logicalViewport.rect.size
            let effectiveScaleFactor: Float
            if logicalViewportSize.width > 0 {
                effectiveScaleFactor = viewportSize.width / logicalViewportSize.width
            } else {
                effectiveScaleFactor = texture.scaleFactor
            }

            // Create UI-specific orthographic projection with origin at top-left
            let uiProjection = Transform3D.createUIProjection(
                width: viewportSize.width,
                height: viewportSize.height,
                scaleFactor: effectiveScaleFactor
            )

            // Update the UI view uniform buffer
            let uiViewUniform = makeUIViewUniform(
                projection: uiProjection
            )

            let uiRenderPassDescriptor = RenderPassDescriptor(
                label: "UI Render Pass",
                colorAttachments: [
                    .init(
                        texture: texture,
                        operation: OperationDescriptor(
                            loadAction: .load,  // Load existing content (don't clear)
                            storeAction: .store
                        ),
                        clearColor: .clear
                    )
                ],
                depthStencilAttachment: nil
            )

            let renderTargetScissor = Rect(
                x: 0,
                y: 0,
                width: Float(texture.width),
                height: Float(texture.height)
            )

            func blitMainTargetToGlassBackground() {
                guard let glassTex = glassBackground.texture else {
                    return
                }
                let blitEncoder = commandBuffer.beginBlitPass(
                    BlitPassDescriptor(label: "Glass Background Blit")
                )
                blitEncoder.copyTextureToTexture(
                    source: texture,
                    sourceOrigin: Origin3D(),
                    sourceSize: Size3D(width: texWidth, height: texHeight),
                    sourceMipLevel: 0,
                    sourceSlice: 0,
                    destination: glassTex,
                    destinationOrigin: Origin3D(),
                    destinationMipLevel: 0,
                    destinationSlice: 0
                )
                blitEncoder.endBlitPass()
            }

            var renderPass: RenderCommandEncoder?

            for item in renderItems.items where item.windowId == nil || item.windowId == targetWindowId {
                let itemUsesGlass = !item.drawData.glassIndexBuffer.isEmpty

                if itemUsesGlass {
                    if let activePass = renderPass {
                        activePass.endRenderPass()
                        renderPass = nil
                    }
                    blitMainTargetToGlassBackground()
                }

                if renderPass == nil {
                    let activePass = commandBuffer.beginRenderPass(uiRenderPassDescriptor)
                    activePass.setVertexBuffer(uiViewUniform, slot: GlobalBufferIndex.viewUniform)
                    activePass.setViewport(camera.viewport.rect)
                    renderPass = activePass
                }

                if let activePass = renderPass {
                    // Reset scissor for each item so clip state from previous draws
                    // never leaks into non-clipped UI primitives.
                    activePass.setScissorRect(renderTargetScissor)
                    try AnyDrawPass(item.drawPass)
                        .render(
                            with: activePass,
                            world: context.world,
                            view: view,
                            item: item
                        )
                }
            }

            renderPass?.endRenderPass()
            commandBuffer.commit()
        }

        return []
    }

    private func makeUIViewUniform(
        projection: Transform3D
    ) -> GlobalViewUniform {
        uiViewUniform.viewProjectionMatrix = projection

        // Update the uniform buffer with UI projection
        let uniform = GlobalViewUniform(
            projectionMatrix: projection,
            viewProjectionMatrix: projection,
            viewMatrix: .identity
        )

        return uniform
    }
}

extension Transform3D {
    /// Creates an orthographic projection matrix for UI rendering.
    /// Origin is at top-left corner, Y increases downward.
    /// - Parameters:
    ///   - width: Viewport width in points.
    ///   - height: Viewport height in points.
    ///   - scaleFactor: Scale factor for HiDPI displays.
    /// - Returns: Orthographic projection matrix.
    public static func createUIProjection(
        width: Float,
        height: Float,
        scaleFactor: Float = 1.0
    ) -> Transform3D {
        // UI orthographic projection with origin at top-left
        // X: 0 to width (left to right)
        // Y: 0 to -height (top to bottom, negated in Rect.toTransform3D)
        return Self.orthographic(
            left: 0,
            right: width / scaleFactor,
            top: 0,
            bottom: -height / scaleFactor,
            zNear: -1000,
            zFar: 1000
        )
    }
}
