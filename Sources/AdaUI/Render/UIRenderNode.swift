//
//  UIRenderNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 19.12.2025.
//

import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

// TODO: - Avoid redrawing if nothing changed.

/// Resource that holds the UI view uniform for rendering.
/// Uses an orthographic projection with origin at top-left corner.
public struct UIViewUniform: Resource {
    public var viewProjectionMatrix: Transform3D = .identity
    private var bufferedViews = FrameUniformCache3D<GlobalViewUniform>()

    public init() {}

    mutating func retainViews(_ views: [Entity.ID]) { bufferedViews.retainViews(views) }

    mutating func write(_ uniform: GlobalViewUniform, view: Entity.ID, pass: Int = 0, device: RenderDevice) -> BufferData<GlobalViewUniform> {
        bufferedViews.write(uniform, view: view, pass: pass, device: device)
    }
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
        GlobalViewUniform,
        ExtractedCameraSource
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

    private let isWindowOverlay: Bool
    public let inputResources: [RenderSlot]

    public init() { self.init(isWindowOverlay: false) }

    init(isWindowOverlay: Bool) {
        self.isWindowOverlay = isWindowOverlay
        self.inputResources = isWindowOverlay ? [] : [RenderSlot(name: InputNode.view, kind: .entity)]
    }

    public func update(from world: World) {
        query.update(from: world)
        _renderItems.update(from: world)
        _primaryWindowId.update(from: world)
        _uiViewUniform.update(from: world)
        _renderDevice.update(from: world)
        _glassBackground.update(from: world)
        var activeViews: [Entity.ID] = []
        query.forEach { _, _, _, _, source in activeViews.append(source.entityId) }
        uiViewUniform.retainViews(activeViews)
    }

    public func execute(
        context: inout Context,
        renderContext: AdaRender.RenderContext
    ) async throws -> [AdaRender.RenderSlotValue] {
        let view = context.viewEntity
        guard isWindowOverlay || view != nil else {
            return []
        }

        var drewWindowOverlay = false
        try query.forEach { entity, camera, target, _, source in
            let targetWindowId = camera.targetWindowId(from: primaryWindowId)
            if isWindowOverlay {
                guard !drewWindowOverlay, camera.isActive, targetWindowId == primaryWindowId.windowId else {
                    return
                }
            } else if entity != view {
                return
            }
            guard let mainTexture = isWindowOverlay ? target.outputTexture : target.mainTexture else {
                return
            }

            // A pixel-perfect camera drew its scene at a low resolution. The UI is not part of that picture: the scene is
            // scaled into a picture of the output's size first, and the UI is drawn onto it at full resolution.
            var texture: RenderTexture = mainTexture
            var uiViewport = isWindowOverlay
                ? Rect(x: 0, y: 0, width: Float(texture.width), height: Float(texture.height))
                : camera.viewport.rect
            var pixelPerfectPresent: (layout: PixelPerfectLayout, settings: PixelPerfectSettings, pictures: PixelPerfectPictures, pipelines: PixelPerfectPipelines)?
            if
                !isWindowOverlay,
                let settings = target.pixelPerfect,
                let output = target.outputTexture,
                let pipelines = context.world.getResource(PixelPerfectPipelines.self),
                let pictures = context.world.getResource(PixelPerfectPictures.self),
                let layout = PixelPerfectLayout(settings: settings, outputSize: Size(width: Float(output.width), height: Float(output.height)))
            {
                texture = pictures.picture(for: source.entityId, size: SizeInt(width: output.width, height: output.height))
                uiViewport = Rect(x: 0, y: 0, width: Float(texture.width), height: Float(texture.height))
                pixelPerfectPresent = (layout, settings, pictures, pipelines)
            }

            let texWidth = texture.width
            let texHeight = texture.height

            // Snapshot main target for glass (must complete before glass fragments sample it).
            if !isWindowOverlay && (glassBackground.texture == nil
                || glassBackground.texture?.width != texWidth
                || glassBackground.texture?.height != texHeight) {
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

            if let present = pixelPerfectPresent {
                PixelPerfectPresenter.present(
                    source: mainTexture,
                    into: texture,
                    layout: present.layout,
                    letterboxColor: present.settings.letterboxColor,
                    pipeline: present.pipelines.intermediate,
                    sampler: present.pipelines.sampler,
                    commandBuffer: commandBuffer,
                    label: "Pixel Perfect Scene"
                )
                present.pictures.markComposed(source.entityId)
            }

            // Get viewport size
            let viewportSize = uiViewport.size
            let logicalViewportSize = camera.logicalViewport.rect.size
            let effectiveScaleFactor: Float
            if isWindowOverlay {
                effectiveScaleFactor = camera.computedData.targetScaleFactor
            } else if logicalViewportSize.width > 0 {
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
            let viewConstants = self.uiViewUniform.write(
                uiViewUniform, view: source.entityId, pass: isWindowOverlay ? 1 : 0, device: renderDevice.renderDevice
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

            func blitMainTargetToGlassBackground(drawData: UIDrawData) {
                guard let glassTex = glassBackground.texture else {
                    return
                }
                let region = GlassBackgroundCapture.region(
                    vertices: drawData.glassVertexBuffer.elements,
                    viewport: uiViewport,
                    scaleFactor: effectiveScaleFactor,
                    textureSize: SizeInt(width: texWidth, height: texHeight)
                )
                let origin = Origin3D(x: Int(region.minX), y: Int(region.minY), z: 0)
                let blitEncoder = commandBuffer.beginBlitPass(
                    BlitPassDescriptor(label: "Glass Background Blit")
                )
                blitEncoder.copyTextureToTexture(
                    source: texture,
                    sourceOrigin: origin,
                    sourceSize: Size3D(width: Int(region.width), height: Int(region.height)),
                    sourceMipLevel: 0,
                    sourceSlice: 0,
                    destination: glassTex,
                    destinationOrigin: origin,
                    destinationMipLevel: 0,
                    destinationSlice: 0
                )
                blitEncoder.endBlitPass()
            }

            var renderPass: RenderCommandEncoder?

            for item in renderItems.items
            where item.isWindowOverlay == isWindowOverlay && (item.windowId == nil || item.windowId == targetWindowId) {
                let itemUsesGlass = !item.drawData.glassIndexBuffer.isEmpty

                if itemUsesGlass {
                    if let activePass = renderPass {
                        activePass.endRenderPass()
                        renderPass = nil
                    }
                    blitMainTargetToGlassBackground(drawData: item.drawData)
                }

                if renderPass == nil {
                    let activePass = commandBuffer.beginRenderPass(uiRenderPassDescriptor)
                    activePass.setVertexBuffer(viewConstants, offset: 0, slot: GlobalBufferIndex.viewUniform)
                    activePass.setViewport(uiViewport)
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
                            view: entity,
                            item: item
                        )
                }
            }

            renderPass?.endRenderPass()
            commandBuffer.commit()
            drewWindowOverlay = isWindowOverlay
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
