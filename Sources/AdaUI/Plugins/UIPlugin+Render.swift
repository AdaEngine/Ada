//
//  UIRenderPlugin.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 04.12.2025.
//

import AdaApp
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaText
import AdaUtils
import Logging
import Math

public struct ExtractedUIComponents: Resource {
    public var components: ContiguousArray<UIComponent> = []
}

public struct ExtractedUIContexts: Resource {
    public var contexts: ContiguousArray<UIGraphicsContext> = []
}

public struct UIRenderBuildState: Resource {
    public var needsRebuild: Bool = true
}

/// Per-layer tessellation cache used during UI render build.
///
/// Cache keys are stable `UILayer` identifiers (`UILayer.id`).
/// Each entry is valid only for the exact layer `version` and is reused only
/// when the layer reports `cacheable == true`.
///
/// Invalidation model:
/// - Re-recording a `UILayer` increments its command version, so stale entries
///   are automatically rejected by version mismatch.
/// - After each build pass, cache entries are pruned only for windows rebuilt
///   by that pass. An idle window keeps its retained layers intact.
///
/// Dirty-rect interaction:
/// - Dirty rectangles still trigger render build (`UIRenderBuildState.needsRebuild`),
///   but unchanged cacheable layers can bypass re-tessellation by reusing
///   cached `UIDrawData` items.
public struct UILayerDrawCache: Resource {
    /// Cached tessellated data keyed by `UILayer.id`.
    public var entries: [UInt64: UILayerDrawCacheEntry] = [:]
    public init() {}
}

/// Cached tessellation payload for a single `UILayer`.
public struct UILayerDrawCacheEntry: Sendable {
    /// Layer command version at the moment the cache entry was built.
    public var version: UInt64
    /// Tessellated draw data slices emitted by this layer in draw order.
    public var drawDataItems: [UIDrawData]
    /// Indicates whether this layer can safely be reused from cache.
    public var cacheable: Bool

    /// Window whose render list owns this cached payload.
    public var windowId: WindowID?

    /// Surrounding rectangular clip that was baked into the emitted draw item.
    /// A layer can move between scroll/clip containers without changing its own
    /// command revision, so the inherited clip participates in cache validity.
    public var clipRect: Rect?

    /// Inherited path mask baked into the cached geometry, in render coordinates.
    public var clipPolygons: [[Vector2]]?

    public init(
        version: UInt64,
        drawDataItems: [UIDrawData],
        cacheable: Bool,
        windowId: WindowID? = nil,
        clipRect: Rect? = nil,
        clipPolygons: [[Vector2]]? = nil
    ) {
        self.version = version
        self.drawDataItems = drawDataItems
        self.cacheable = cacheable
        self.windowId = windowId
        self.clipRect = clipRect
        self.clipPolygons = clipPolygons
    }
}

@System
public func ExtractUIComponents(
    _ uiComponents: Extract<
        Query<UIComponent>
    >,
    _ pendingViews: Extract<
        Res<UIWindowPendingDrawViews>
    >,
    _ contexts: Extract<
        Res<UIContextPendingDraw>
    >,
    _ redrawRequest: Extract<
        Res<UIRedrawRequest>
    >,
    _ extractedUIComponents: ResMut<ExtractedUIComponents>,
    _ extractedUIContexts: ResMut<ExtractedUIContexts>,
    _ buildState: ResMut<UIRenderBuildState>
) {
    extractedUIComponents.components.removeAll(keepingCapacity: true)
    extractedUIContexts.contexts.removeAll(keepingCapacity: true)

    pendingViews().windows
        .forEach {
            extractedUIComponents.components.append(
                UIComponent(view: $0, behaviour: .default, windowRef: .windowId($0.id))
            )
        }
    uiComponents()
        .forEach {
            extractedUIComponents.components.append($0)
        }
    extractedUIContexts.contexts.append(contentsOf: contexts().contexts)

    buildState.needsRebuild =
        redrawRequest().needsRedraw
        || !pendingViews().windows.isEmpty
        || !contexts().contexts.isEmpty
}

public struct PendingUIGraphicsContext: Resource {
    public var graphicContexts: ContiguousArray<UIGraphicsContext> = []
}

@System(
    dependencies: [.after("AdaRender.ConfigurateRenderViewTargetSystem")]
)
@MainActor
public func UIRenderPreparing(
    _ uiComponents: Res<ExtractedUIComponents>,
    _ contexts: ResMut<PendingUIGraphicsContext>,
    _ extractedUIContexts: ResMut<ExtractedUIContexts>,
    _ buildState: ResMut<UIRenderBuildState>,
    _ primaryWindowId: Res<PrimaryWindowId>
) {
    guard buildState.needsRebuild else {
        return
    }
    contexts.graphicContexts.removeAll(keepingCapacity: true)
    uiComponents.components.forEach { component in
        var context = UIGraphicsContext()
        context.windowId = component.windowRef.getWindowId(from: primaryWindowId.wrappedValue)
        component.view.draw(with: context)
        context.commitDraw()
        contexts.graphicContexts.append(context)
    }
    contexts.graphicContexts.append(contentsOf: extractedUIContexts.contexts)
}

// MARK: - UIRenderTesselationSystem

/// System that tessellates UI draw commands into vertex and index data.
@PlainSystem
public struct UIRenderTesselationSystem {
    /// Maximum number of textures per batch.
    private static let maxTexturesPerBatch = 16

    @ResMut<RenderItems<UITransparentRenderItem>>
    private var renderItems

    @ResMut<PendingUIGraphicsContext>
    private var contexts

    @ResMut<UIRenderBuildState>
    private var buildState

    @ResMut<UILayerDrawCache>
    private var layerDrawCache

    @Res<UIDrawPass>
    private var uiDrawPass

    @Res<RenderDeviceHandler>
    private var renderDevice

    @Res<UIRenderPipelines>
    private var renderPipelines

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        guard buildState.needsRebuild else {
            return
        }
        removeStaleRenderItems()

        let tessellator = UITessellator()
        var sortKey: Float = 0
        var activeLayerIDs = Set<UInt64>()
        var rebuiltWindowIds = Set<WindowID?>()

        contexts.graphicContexts.forEach { graphicsContext in
            let windowId = graphicsContext.windowId
            rebuiltWindowIds.insert(windowId)
            var rootState = DrawBuildState()
            var layerStack: [ActiveLayer] = []

            for command in graphicsContext.getDrawCommands() {
                switch command {
                case let .beginLayer(id, version, cacheable):
                    activeLayerIDs.insert(id)
                    var inheritedState = layerStack.last?.state ?? rootState
                    if let parentIndex = layerStack.indices.last {
                        // A parent's slices are emitted around its children. Caching
                        // only its final slice would lose/reorder earlier geometry.
                        // Rebuild container layers and cache their leaf layers instead.
                        layerStack[parentIndex].cacheable = false
                    }
                    // Flush current state to preserve draw order.
                    if layerStack.isEmpty {
                        flushStateIfNeeded(&rootState, renderDevice: renderDevice.renderDevice).map { rootState.drawDataItems.append($0) }
                        appendRenderItems(rootState.drawDataItems, sortKey: &sortKey, windowId: windowId)
                        rootState.drawDataItems.removeAll(keepingCapacity: true)
                        inheritedState = rootState
                    } else if layerStack[layerStack.count - 1].mode == .building {
                        flushStateIfNeeded(&layerStack[layerStack.count - 1].state, renderDevice: renderDevice.renderDevice)
                            .map {
                                layerStack[layerStack.count - 1].state.drawDataItems.append($0)
                            }
                        appendRenderItems(layerStack[layerStack.count - 1].state.drawDataItems, sortKey: &sortKey, windowId: windowId)
                        layerStack[layerStack.count - 1].state.drawDataItems.removeAll(keepingCapacity: true)
                        inheritedState = layerStack[layerStack.count - 1].state
                    }

                    let canUseLayerCache = cacheable
                    if canUseLayerCache,
                        let cached = layerDrawCache.entries[id],
                        cached.version == version,
                        cached.cacheable,
                        cached.clipRect == inheritedState.currentClipRect,
                        cached.clipPolygons == inheritedState.currentClipPolygons {
                        appendRenderItems(cached.drawDataItems, sortKey: &sortKey, windowId: windowId)
                        layerStack.append(ActiveLayer(id: id, version: version, mode: .skipping, cacheable: cacheable, state: inheritedState))
                    } else {
                        layerStack.append(ActiveLayer(id: id, version: version, mode: .building, cacheable: canUseLayerCache, state: inheritedState))
                    }

                case let .endLayer(id):
                    guard var layer = layerStack.popLast() else {
                        continue
                    }

                    guard layer.id == id else {
                        continue
                    }

                    switch layer.mode {
                    case .skipping:
                        break
                    case .building:
                        flushStateIfNeeded(&layer.state, renderDevice: renderDevice.renderDevice).map { layer.state.drawDataItems.append($0) }
                        appendRenderItems(layer.state.drawDataItems, sortKey: &sortKey, windowId: windowId)

                        cacheLayer(layer, windowId: windowId)
                    }

                default:
                    if let topIndex = layerStack.indices.last {
                        switch layerStack[topIndex].mode {
                        case .skipping:
                            break
                        case .building:
                            processCommand(
                                command,
                                state: &layerStack[topIndex].state,
                                tessellator: tessellator,
                                renderDevice: renderDevice.renderDevice
                            )
                        }
                    } else {
                        processCommand(
                            command,
                            state: &rootState,
                            tessellator: tessellator,
                            renderDevice: renderDevice.renderDevice
                        )
                    }
                }
            }

            flushStateIfNeeded(
                &rootState,
                renderDevice: renderDevice.renderDevice
            )
            .map { rootState.drawDataItems.append($0) }
            appendRenderItems(rootState.drawDataItems, sortKey: &sortKey, windowId: windowId)
        }

        if !layerDrawCache.entries.isEmpty {
            // Only windows represented by this partial rebuild can prove that
            // one of their former layers disappeared. Preserve idle windows.
            layerDrawCache.entries = layerDrawCache.entries.filter { id, entry in
                !rebuiltWindowIds.contains(entry.windowId) || activeLayerIDs.contains(id)
            }
        }

        buildState.needsRebuild = false
    }

    private func cacheLayer(_ layer: ActiveLayer, windowId: WindowID?) {
        guard layer.cacheable else {
            layerDrawCache.entries[layer.id] = nil
            return
        }
        layerDrawCache.entries[layer.id] = UILayerDrawCacheEntry(
            version: layer.version,
            drawDataItems: layer.state.drawDataItems,
            cacheable: true,
            windowId: windowId,
            clipRect: layer.inheritedClipRect,
            clipPolygons: layer.inheritedClipPolygons
        )
    }

    private func removeStaleRenderItems() {
        let rebuiltWindowIds = Set(contexts.graphicContexts.compactMap(\.windowId))
        let rebuildsGlobalItems = contexts.graphicContexts.contains { $0.windowId == nil }

        guard !rebuiltWindowIds.isEmpty, !rebuildsGlobalItems else {
            renderItems.items.removeAll()
            return
        }

        renderItems.items.removeAll { item in
            guard let windowId = item.windowId else {
                return false
            }
            return rebuiltWindowIds.contains(windowId)
        }
    }

    private struct DrawBuildState {
        var renderData: UIDrawData = UIDrawData()
        var drawDataItems: [UIDrawData] = []
        var currentLineWidth: Float = 1.0
        var currentClipRect: Rect?
        var clipStack: [Rect?] = []
        var currentClipPolygons: [[Vector2]]?
        var clipPolygonStack: [[[Vector2]]?] = []

        init(
            currentClipRect: Rect? = nil,
            clipStack: [Rect?] = [],
            currentClipPolygons: [[Vector2]]? = nil,
            clipPolygonStack: [[[Vector2]]?] = []
        ) {
            self.currentClipRect = currentClipRect
            self.clipStack = clipStack
            self.currentClipPolygons = currentClipPolygons
            self.clipPolygonStack = clipPolygonStack
            renderData.textures = [.whiteTexture]
            renderData.fontAtlases = []
            renderData.clipRect = currentClipRect
        }
    }

    private struct ActiveLayer {
        enum Mode {
            case building
            case skipping
        }

        var id: UInt64
        var version: UInt64
        var mode: Mode
        var cacheable: Bool
        var state: DrawBuildState
        let inheritedClipRect: Rect?
        let inheritedClipPolygons: [[Vector2]]?

        init(id: UInt64, version: UInt64, mode: Mode, cacheable: Bool, state: DrawBuildState = DrawBuildState()) {
            self.id = id
            self.version = version
            self.mode = mode
            self.cacheable = cacheable
            self.state = state
            self.inheritedClipRect = state.currentClipRect
            self.inheritedClipPolygons = state.currentClipPolygons
        }
    }

    private func appendRenderItems(
        _ items: [UIDrawData],
        sortKey: inout Float,
        windowId: WindowID?
    ) {
        for drawData in items {
            self.renderItems.items.append(
                UITransparentRenderItem(
                    sortKey: sortKey,
                    windowId: windowId,
                    entity: .zero,
                    drawPass: uiDrawPass,
                    primitiveType: .quad,
                    renderPipeline: renderPipelines,
                    drawData: drawData
                )
            )
            sortKey += 1
        }
    }

    private func flushStateIfNeeded(
        _ state: inout DrawBuildState,
        renderDevice: any RenderDevice
    ) -> UIDrawData? {
        guard !state.renderData.isEmpty else {
            return nil
        }

        let accumulatedDrawDataItems = state.drawDataItems
        state.renderData.write(to: renderDevice)
        let flushed = state.renderData
        state = DrawBuildState(
            currentClipRect: state.currentClipRect,
            clipStack: state.clipStack,
            currentClipPolygons: state.currentClipPolygons,
            clipPolygonStack: state.clipPolygonStack
        )
        state.drawDataItems = accumulatedDrawDataItems
        return flushed
    }

    private func processCommand(
        _ command: UIGraphicsContext.DrawCommand,
        state: inout DrawBuildState,
        tessellator: UITessellator,
        renderDevice: any RenderDevice
    ) {
        // These stacks contain optional values, making popLast() doubly optional.
        // swiftlint:disable redundant_nil_coalescing
        switch command {
        case .beginLayer,
            .endLayer:
            break
        case let .pushClipRect(rect):
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
            state.clipStack.append(state.currentClipRect)
            if let currentClipRect = state.currentClipRect {
                state.currentClipRect = intersectRects(currentClipRect, rect) ?? .zero
            } else {
                state.currentClipRect = rect
            }
            state.renderData.clipRect = state.currentClipRect
        case .popClipRect:
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
            state.currentClipRect = state.clipStack.popLast() ?? nil
            state.renderData.clipRect = state.currentClipRect
        case let .pushClipPath(path, transform):
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
            state.clipPolygonStack.append(state.currentClipPolygons)
            let polygons = tessellator.clipPathPolygons(path, transform: transform)
            if let currentClipPolygons = state.currentClipPolygons {
                state.currentClipPolygons = tessellator.clipPolygons(currentClipPolygons, to: polygons)
            } else {
                state.currentClipPolygons = polygons
            }
        case .popClipPath:
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
            state.currentClipPolygons = state.clipPolygonStack.popLast() ?? nil
        case let .setLineWidth(lineWidth):
            state.currentLineWidth = lineWidth

        case let .drawQuad(transform, texture, color):
            let textureToUse = texture ?? .whiteTexture
            var texIndex = findOrAddTexture(
                textureToUse,
                in: &state.renderData.textures
            )
            if texIndex == nil {
                flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
                texIndex = findOrAddTexture(
                    textureToUse,
                    in: &state.renderData.textures
                )
            }
            guard let texIndex else {
                return
            }

            let indexStart = state.renderData.quadIndexBuffer.count
            let indexCount: Int
            if let clipPolygons = state.currentClipPolygons {
                let result = tessellator.tessellateClippedQuad(
                    transform: transform,
                    texture: texture,
                    color: color,
                    textureIndex: texIndex,
                    clipPolygons: clipPolygons
                )
                let vertexOffset = UInt32(state.renderData.quadVertexBuffer.count)
                state.renderData.quadVertexBuffer.elements.append(contentsOf: result.vertices)
                let indices = result.indices.map { $0 + vertexOffset }
                state.renderData.quadIndexBuffer.elements.append(contentsOf: indices)
                indexCount = indices.count
            } else {
                tessellator.appendQuad(
                    transform: transform,
                    texture: texture,
                    color: color,
                    textureIndex: texIndex,
                    vertices: &state.renderData.quadVertexBuffer.elements,
                    indices: &state.renderData.quadIndexBuffer.elements
                )
                indexCount = 6
            }
            guard indexCount > 0 else {
                return
            }
            appendBatch(
                textureIndex: texIndex,
                indexStart: indexStart,
                indexCount: indexCount,
                batches: &state.renderData.quadBatches
            )

        case let .drawShaderEffect(transform, material):
            // Keep custom material draws in their own item so each material can bind
            // its own pipeline and reflected resources without reordering UI content.
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }

            let indexStart = state.renderData.shaderEffectIndexBuffer.count
            let indices: [UInt32]
            if let clipPolygons = state.currentClipPolygons {
                let result = tessellator.tessellateClippedShaderEffect(
                    transform: transform,
                    clipPolygons: clipPolygons
                )
                let vertexOffset = UInt32(state.renderData.shaderEffectVertexBuffer.count)
                state.renderData.shaderEffectVertexBuffer.elements.append(contentsOf: result.vertices)
                indices = result.indices.map { $0 + vertexOffset }
            } else {
                let vertexOffset = UInt32(state.renderData.shaderEffectVertexBuffer.count)
                let vertices = tessellator.tessellateShaderEffect(transform: transform)
                state.renderData.shaderEffectVertexBuffer.elements.append(contentsOf: vertices)
                indices = tessellator.generateQuadIndices(vertexOffset: vertexOffset)
            }
            guard !indices.isEmpty else {
                return
            }
            state.renderData.shaderEffectIndexBuffer.elements.append(contentsOf: indices)
            state.renderData.shaderEffectBatches.append(
                UIDrawData.ShaderEffectBatch(
                    material: material,
                    indexOffset: indexStart,
                    indexCount: indices.count
                )
            )

            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }

        case let .drawLinearGradient(transform, startPoint, endPoint, stops):
            // Gradients use their own pipeline, so keep them in a dedicated
            // draw item to preserve their position in the view hierarchy.
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }

            let indexStart = state.renderData.gradientIndexBuffer.count
            let indexCount: Int
            if let clipPolygons = state.currentClipPolygons {
                let result = tessellator.tessellateClippedLinearGradient(
                    transform: transform,
                    clipPolygons: clipPolygons
                )
                let vertexOffset = UInt32(state.renderData.gradientVertexBuffer.count)
                state.renderData.gradientVertexBuffer.elements.append(contentsOf: result.vertices)
                let indices = result.indices.map { $0 + vertexOffset }
                state.renderData.gradientIndexBuffer.elements.append(contentsOf: indices)
                indexCount = indices.count
            } else {
                tessellator.appendLinearGradient(
                    transform: transform,
                    vertices: &state.renderData.gradientVertexBuffer.elements,
                    indices: &state.renderData.gradientIndexBuffer.elements
                )
                indexCount = 6
            }
            guard indexCount > 0 else {
                return
            }

            let uniformIndex = state.renderData.gradientUniformBuffer.count
            state.renderData.gradientUniformBuffer.append(
                LinearGradientUniform(
                    startPoint: startPoint,
                    endPoint: endPoint,
                    stops: stops
                )
            )
            state.renderData.gradientBatches.append(
                UIDrawData.LinearGradientBatch(
                    indexOffset: indexStart,
                    indexCount: indexCount,
                    uniformOffset: uniformIndex * MemoryLayout<LinearGradientUniform>.stride
                )
            )

            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }

        case let .drawCircle(transform, thickness, fade, color):
            let vertexOffset = UInt32(state.renderData.circleVertexBuffer.count)
            let vertices = tessellator.tessellateCircle(
                transform: transform,
                thickness: thickness,
                fade: fade,
                color: color
            )
            state.renderData.circleVertexBuffer.elements.append(contentsOf: vertices)

            let indices = tessellator.generateCircleIndices(vertexOffset: vertexOffset)
            state.renderData.circleIndexBuffer.elements.append(contentsOf: indices)

        case let .drawLine(start, end, lineWidth, color):
            let vertexOffset = UInt32(state.renderData.lineVertexBuffer.count)
            let vertices = tessellator.tessellateLine(
                start: start,
                end: end,
                lineWidth: lineWidth,
                color: color
            )
            state.renderData.lineVertexBuffer.elements.append(contentsOf: vertices)

            let indices = tessellator.generateLineIndices(vertexOffset: vertexOffset)
            state.renderData.lineIndexBuffer.elements.append(contentsOf: indices)

        case let .drawPath(path, transform, mode):
            switch mode {
            case .legacy:
                let result = tessellator.tessellatePathStroke(
                    path,
                    lineWidth: state.currentLineWidth,
                    color: .white,
                    transform: transform
                )

                let vertexOffset = UInt32(state.renderData.lineVertexBuffer.count)
                state.renderData.lineVertexBuffer.elements.append(contentsOf: result.vertices)

                let indices = result.indices.map { $0 + vertexOffset }
                state.renderData.lineIndexBuffer.elements.append(contentsOf: indices)

            case let .stroke(color, style):
                let result = tessellator.tessellatePathStroke(
                    path,
                    lineWidth: style.lineWidth,
                    color: color,
                    transform: transform
                )

                let vertexOffset = UInt32(state.renderData.lineVertexBuffer.count)
                state.renderData.lineVertexBuffer.elements.append(contentsOf: result.vertices)

                let indices = result.indices.map { $0 + vertexOffset }
                state.renderData.lineIndexBuffer.elements.append(contentsOf: indices)

            case let .fill(color):
                let textureToUse = Texture2D.whiteTexture
                var texIndex = findOrAddTexture(
                    textureToUse,
                    in: &state.renderData.textures
                )
                if texIndex == nil {
                    flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
                    texIndex = findOrAddTexture(
                        textureToUse,
                        in: &state.renderData.textures
                    )
                }
                guard let texIndex else {
                    return
                }

                let result = tessellator.tessellatePathFill(
                    path,
                    color: color,
                    transform: transform,
                    textureIndex: texIndex,
                    clipPolygons: state.currentClipPolygons
                )
                guard !result.indices.isEmpty else {
                    return
                }

                let vertexOffset = UInt32(state.renderData.quadVertexBuffer.count)
                state.renderData.quadVertexBuffer.elements.append(contentsOf: result.vertices)

                let indexStart = state.renderData.quadIndexBuffer.count
                let indices = result.indices.map { $0 + vertexOffset }
                state.renderData.quadIndexBuffer.elements.append(contentsOf: indices)
                appendBatch(
                    textureIndex: texIndex,
                    indexStart: indexStart,
                    indexCount: indices.count,
                    batches: &state.renderData.quadBatches
                )
            }

        case let .drawText(textLayout, transform, opacity):
            let textSize = textLayout.boundingSize()
            let textAlignment = textLayout.resolvedTextAlignment

            var offsetY: Float = 0

            if let firstLine = textLayout.textLines.first, !textLayout.textLines.isEmpty {
                let topY = firstLine.typographicBounds.rect.origin.y
                let bottomY = topY - textSize.height
                offsetY = -(topY + bottomY) / 2
            }

            for line in textLayout.textLines {
                let lineBounds = textLayout.visualBounds(for: line)
                let lineOffsetX: Float =
                    switch textAlignment {
                    case .center:
                        -((lineBounds.minX + lineBounds.maxX) / 2)
                    case .leading:
                        -lineBounds.minX
                    case .trailing:
                        -lineBounds.maxX
                    }

                for run in line {
                    for glyph in run {
                        let glyphOffset = Vector2(x: lineOffsetX, y: -offsetY)

                        tessellateGlyph(
                            glyph,
                            transform: transform,
                            offset: glyphOffset,
                            opacity: opacity,
                            tessellator: tessellator,
                            state: &state,
                            renderDevice: renderDevice
                        )
                    }
                }
            }

        case let .drawGlyph(glyph, transform, opacity):
            tessellateGlyph(
                glyph,
                transform: transform,
                opacity: opacity,
                tessellator: tessellator,
                state: &state,
                renderDevice: renderDevice
            )

        case let .drawGlassRect(transform, halfSize, configuration, scaleFactor):
            // Flush any queued non-glass draws to preserve correct draw order.
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }

            let vertexOffset = UInt32(state.renderData.glassVertexBuffer.count)
            let vertices = tessellator.tessellateGlassQuad(
                transform: transform,
                halfSize: halfSize,
                configuration: configuration,
                scaleFactor: scaleFactor
            )
            state.renderData.glassVertexBuffer.elements.append(contentsOf: vertices)

            let indexStart = state.renderData.glassIndexBuffer.count
            let indices = tessellator.generateQuadIndices(vertexOffset: vertexOffset)
            state.renderData.glassIndexBuffer.elements.append(contentsOf: indices)
            state.renderData.glassBatches.append(
                UIDrawData.IndexBatch(textureIndex: 0, indexOffset: indexStart, indexCount: indices.count)
            )

            // Flush immediately so that content drawn after this command renders on top.
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }

        case .commit:
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
        }
        // swiftlint:enable redundant_nil_coalescing
    }

    // MARK: - Private Helpers

    private func findOrAddTexture(
        _ texture: Texture2D,
        in textures: inout [Texture2D]
    ) -> Int? {
        // Check if texture already exists
        if let existingIndex = textures.firstIndex(where: { $0 === texture }) {
            return existingIndex
        }

        // Add new texture if we have room.
        if textures.count < Self.maxTexturesPerBatch {
            textures.append(texture)
            return textures.count - 1
        }

        // Batch is full: caller should flush and retry.
        return nil
    }

    private func tessellateGlyph(
        _ glyph: Glyph,
        transform: Transform3D,
        offset: Vector2 = .zero,
        opacity: Float = 1,
        tessellator: UITessellator,
        state: inout DrawBuildState,
        renderDevice: any RenderDevice
    ) {
        var texIndex = findOrAddTexture(
            glyph.textureAtlas,
            in: &state.renderData.fontAtlases
        )
        if texIndex == nil {
            flushStateIfNeeded(&state, renderDevice: renderDevice).map { state.drawDataItems.append($0) }
            texIndex = findOrAddTexture(
                glyph.textureAtlas,
                in: &state.renderData.fontAtlases
            )
        }
        guard let texIndex else {
            return
        }

        let indexStart = state.renderData.glyphIndexBuffer.count
        let indexCount: Int
        if let clipPolygons = state.currentClipPolygons {
            let result = tessellator.tessellateClippedGlyph(
                glyph,
                transform: transform,
                textureIndex: texIndex,
                offset: offset,
                opacity: opacity,
                clipPolygons: clipPolygons
            )
            let vertexOffset = UInt32(state.renderData.glyphVertexBuffer.count)
            state.renderData.glyphVertexBuffer.elements.append(contentsOf: result.vertices)
            let indices = result.indices.map { $0 + vertexOffset }
            state.renderData.glyphIndexBuffer.elements.append(contentsOf: indices)
            indexCount = indices.count
        } else {
            tessellator.appendGlyph(
                glyph,
                transform: transform,
                textureIndex: texIndex,
                offset: offset,
                opacity: opacity,
                vertices: &state.renderData.glyphVertexBuffer.elements,
                indices: &state.renderData.glyphIndexBuffer.elements
            )
            indexCount = 6
        }
        guard indexCount > 0 else {
            return
        }
        appendBatch(
            textureIndex: texIndex,
            indexStart: indexStart,
            indexCount: indexCount,
            batches: &state.renderData.glyphBatches
        )
    }

    private func appendBatch(
        textureIndex: Int,
        indexStart: Int,
        indexCount: Int,
        batches: inout [UIDrawData.IndexBatch]
    ) {
        if var lastBatch = batches.last, lastBatch.textureIndex == textureIndex {
            let expectedStart = lastBatch.indexOffset + lastBatch.indexCount
            if expectedStart == indexStart {
                lastBatch.indexCount += indexCount
                batches[batches.count - 1] = lastBatch
                return
            }
        }

        batches.append(
            UIDrawData.IndexBatch(
                textureIndex: textureIndex,
                indexOffset: indexStart,
                indexCount: indexCount
            )
        )
    }

    private func intersectRects(_ lhs: Rect, _ rhs: Rect) -> Rect? {
        let minX = max(lhs.minX, rhs.minX)
        let minY = max(lhs.minY, rhs.minY)
        let maxX = min(lhs.maxX, rhs.maxX)
        let maxY = min(lhs.maxY, rhs.maxY)

        guard maxX > minX, maxY > minY else {
            return nil
        }

        return Rect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

public struct UIRenderPipelines: Resource, WorldInitable {
    public var textPipeline: RenderPipeline
    public var quadPipeline: RenderPipeline
    public var gradientPipeline: RenderPipeline
    public var linePipeline: RenderPipeline
    public var circlePipeline: RenderPipeline
    /// Pipeline for ``GlassEffectModifier`` / `glass.glsl` (requires `RenderPipelines<GlassPipeline>` on the render world).
    public var glassPipeline: RenderPipeline

    public init(from world: World) {
        let device = world.getResource(RenderDeviceHandler.self).unwrap().renderDevice
        self.textPipeline = world.getRefResource(RenderPipelines<TextPipeline>.self)
            .wrappedValue
            .pipeline(device: device)

        self.quadPipeline = world.getRefResource(RenderPipelines<QuadPipeline>.self)
            .wrappedValue
            .pipeline(device: device)

        self.gradientPipeline = world.getRefResource(RenderPipelines<LinearGradientPipeline>.self)
            .wrappedValue
            .pipeline(device: device)

        self.linePipeline = world.getRefResource(RenderPipelines<LinePipeline>.self)
            .wrappedValue
            .pipeline(device: device)

        self.circlePipeline = world.getRefResource(RenderPipelines<CirclePipeline>.self)
            .wrappedValue
            .pipeline(device: device)

        // Must succeed when UIPlugin registered `RenderPipelines<GlassPipeline>()` on this world.
        self.glassPipeline = world.getRefResource(RenderPipelines<GlassPipeline>.self)
            .wrappedValue
            .pipeline(device: device)
    }
}

// MARK: - UIRenderItem

/// Render item for UI primitives.
public struct UITransparentRenderItem: RenderItem {
    public var sortKey: Float
    public var windowId: WindowID?
    public var entity: Entity.ID
    public var drawPass: any DrawPass
    public var batchRange: Range<Int32>?
    public var renderPipeline: UIRenderPipelines
    public var drawData: UIDrawData

    /// Type of UI primitive being rendered.
    public enum PrimitiveType: Sendable {
        case quad
        case circle
        case line
        case glyph
    }

    public var primitiveType: PrimitiveType

    public init(
        sortKey: Float,
        windowId: WindowID? = nil,
        entity: Entity.ID,
        drawPass: any DrawPass,
        primitiveType: PrimitiveType,
        batchRange: Range<Int32>? = nil,
        renderPipeline: UIRenderPipelines,
        drawData: UIDrawData
    ) {
        self.sortKey = sortKey
        self.windowId = windowId
        self.entity = entity
        self.drawPass = drawPass
        self.primitiveType = primitiveType
        self.batchRange = batchRange
        self.renderPipeline = renderPipeline
        self.drawData = drawData
    }
}
