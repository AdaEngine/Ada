//
//  UIDrawPass.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 19.12.2025.
//

import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaText
import AdaUtils
import Math

// MARK: - UI Draw Data

struct LinearGradientUniform: Sendable {
    let startPoint: Vector2
    let endPoint: Vector2
    let stopCount: Int32
    let _padding: Int32
    let _padding1: Int32
    let _padding2: Int32
    let stopColor0: Vector4
    let stopColor1: Vector4
    let stopColor2: Vector4
    let stopColor3: Vector4
    let stopColor4: Vector4
    let stopColor5: Vector4
    let stopColor6: Vector4
    let stopColor7: Vector4
    let stopColor8: Vector4
    let stopColor9: Vector4
    let stopColor10: Vector4
    let stopColor11: Vector4
    let stopColor12: Vector4
    let stopColor13: Vector4
    let stopColor14: Vector4
    let stopColor15: Vector4
    let stopLocations0: Vector4
    let stopLocations1: Vector4
    let stopLocations2: Vector4
    let stopLocations3: Vector4

    init(startPoint: Vector2, endPoint: Vector2, stops: [Gradient.Stop]) {
        let normalizedStops = Gradient.normalizeStops(stops)
        let colors = Self.makeColors(from: normalizedStops)
        let locations = Self.makeLocations(from: normalizedStops)

        self.startPoint = startPoint
        self.endPoint = endPoint
        self.stopCount = Int32(normalizedStops.count)
        self._padding = 0
        self._padding1 = 0
        self._padding2 = 0
        self.stopColor0 = colors[0]
        self.stopColor1 = colors[1]
        self.stopColor2 = colors[2]
        self.stopColor3 = colors[3]
        self.stopColor4 = colors[4]
        self.stopColor5 = colors[5]
        self.stopColor6 = colors[6]
        self.stopColor7 = colors[7]
        self.stopColor8 = colors[8]
        self.stopColor9 = colors[9]
        self.stopColor10 = colors[10]
        self.stopColor11 = colors[11]
        self.stopColor12 = colors[12]
        self.stopColor13 = colors[13]
        self.stopColor14 = colors[14]
        self.stopColor15 = colors[15]
        self.stopLocations0 = locations[0]
        self.stopLocations1 = locations[1]
        self.stopLocations2 = locations[2]
        self.stopLocations3 = locations[3]
    }
}

extension LinearGradientUniform {
    private static func makeColors(from stops: [Gradient.Stop]) -> [Vector4] {
        var colors = Array(repeating: Color.clear.asVector, count: Gradient.maximumStops)
        for (index, stop) in stops.enumerated() where index < Gradient.maximumStops {
            colors[index] = stop.color.asVector
        }
        return colors
    }

    private static func makeLocations(from stops: [Gradient.Stop]) -> [Vector4] {
        var flatLocations = Array(repeating: Float(1), count: Gradient.maximumStops)
        for (index, stop) in stops.enumerated() where index < Gradient.maximumStops {
            flatLocations[index] = stop.location
        }

        return stride(from: 0, to: Gradient.maximumStops, by: 4)
            .map { index in
                Vector4(
                    flatLocations[index],
                    flatLocations[index + 1],
                    flatLocations[index + 2],
                    flatLocations[index + 3]
                )
            }
    }
}

/// Resource that holds GPU buffers for UI rendering.
public struct UIDrawData: Sendable {
    public struct IndexBatch: Sendable {
        public var textureIndex: Int
        public var indexOffset: Int
        public var indexCount: Int

        public init(textureIndex: Int, indexOffset: Int, indexCount: Int) {
            self.textureIndex = textureIndex
            self.indexOffset = indexOffset
            self.indexCount = indexCount
        }
    }

    public struct LinearGradientBatch: Sendable {
        public var indexOffset: Int
        public var indexCount: Int
        public var uniformOffset: Int

        public init(indexOffset: Int, indexCount: Int, uniformOffset: Int) {
            self.indexOffset = indexOffset
            self.indexCount = indexCount
            self.uniformOffset = uniformOffset
        }
    }

    public struct ShaderEffectBatch: Sendable {
        public var material: Material
        public var indexOffset: Int
        public var indexCount: Int

        public init(material: Material, indexOffset: Int, indexCount: Int) {
            self.material = material
            self.indexOffset = indexOffset
            self.indexCount = indexCount
        }
    }

    /// Vertex buffer for quads.
    public var quadVertexBuffer: BufferData<QuadVertexData>
    /// Index buffer for quads.
    public var quadIndexBuffer: BufferData<UInt32>

    /// Vertex buffer for linear gradients.
    public var gradientVertexBuffer: BufferData<QuadVertexData>
    /// Index buffer for linear gradients.
    public var gradientIndexBuffer: BufferData<UInt32>
    /// Uniform buffer for linear gradients.
    var gradientUniformBuffer: BufferData<LinearGradientUniform>

    /// Vertex buffer for shader effect quads.
    public var shaderEffectVertexBuffer: BufferData<QuadVertexData>
    /// Index buffer for shader effect quads.
    public var shaderEffectIndexBuffer: BufferData<UInt32>

    /// Vertex buffer for circles.
    public var circleVertexBuffer: BufferData<CircleVertexData>
    /// Index buffer for circles.
    public var circleIndexBuffer: BufferData<UInt32>

    /// Vertex buffer for lines.
    public var lineVertexBuffer: BufferData<LineVertexData>
    /// Index buffer for lines.
    public var lineIndexBuffer: BufferData<UInt32>

    /// Vertex buffer for glyphs.
    public var glyphVertexBuffer: BufferData<GlyphVertexData>
    /// Index buffer for glyphs.
    public var glyphIndexBuffer: BufferData<UInt32>

    /// Vertex buffer for glass quads.
    public var glassVertexBuffer: BufferData<GlassVertexData>
    /// Index buffer for glass quads.
    public var glassIndexBuffer: BufferData<UInt32>

    /// Textures used for quad rendering (max 16 per batch).
    public var textures: [Texture2D] = []

    /// Batches for quad rendering.
    public var quadBatches: [IndexBatch] = []

    /// Batches for linear gradient rendering.
    public var gradientBatches: [LinearGradientBatch] = []

    /// Batches for custom shader effect rendering.
    public var shaderEffectBatches: [ShaderEffectBatch] = []

    /// Font atlas textures used for text rendering (max 16 per batch).
    public var fontAtlases: [Texture2D] = []

    /// Batches for glyph rendering.
    public var glyphBatches: [IndexBatch] = []

    /// Batches for glass rendering (always uses the background texture).
    public var glassBatches: [IndexBatch] = []

    /// Optional clip rectangle in viewport coordinates.
    public var clipRect: Rect?

    public init() {
        self.quadVertexBuffer = BufferData(label: "UI_QuadVertexBuffer", elements: [])
        self.quadIndexBuffer = BufferData(label: "UI_QuadIndexBuffer", elements: [])
        self.gradientVertexBuffer = BufferData(label: "UI_GradientVertexBuffer", elements: [])
        self.gradientIndexBuffer = BufferData(label: "UI_GradientIndexBuffer", elements: [])
        self.gradientUniformBuffer = BufferData(label: "UI_GradientUniformBuffer", elements: [])
        self.shaderEffectVertexBuffer = BufferData(label: "UI_ShaderEffectVertexBuffer", elements: [])
        self.shaderEffectIndexBuffer = BufferData(label: "UI_ShaderEffectIndexBuffer", elements: [])
        self.circleVertexBuffer = BufferData(label: "UI_CircleVertexBuffer", elements: [])
        self.circleIndexBuffer = BufferData(label: "UI_CircleIndexBuffer", elements: [])
        self.lineVertexBuffer = BufferData(label: "UI_LineVertexBuffer", elements: [])
        self.lineIndexBuffer = BufferData(label: "UI_LineIndexBuffer", elements: [])
        self.glyphVertexBuffer = BufferData(label: "UI_GlyphVertexBuffer", elements: [])
        self.glyphIndexBuffer = BufferData(label: "UI_GlyphIndexBuffer", elements: [])
        self.glassVertexBuffer = BufferData(label: "UI_GlassVertexBuffer", elements: [])
        self.glassIndexBuffer = BufferData(label: "UI_GlassIndexBuffer", elements: [])
        self.clipRect = nil
    }

    public mutating func write(to device: any RenderDevice) {
        self.quadVertexBuffer.write(to: device)
        self.quadIndexBuffer.write(to: device)
        self.gradientVertexBuffer.write(to: device)
        self.gradientIndexBuffer.write(to: device)
        self.gradientUniformBuffer.write(to: device)
        self.shaderEffectVertexBuffer.write(to: device)
        self.shaderEffectIndexBuffer.write(to: device)
        self.circleVertexBuffer.write(to: device)
        self.circleIndexBuffer.write(to: device)
        self.lineVertexBuffer.write(to: device)
        self.lineIndexBuffer.write(to: device)
        self.glyphVertexBuffer.write(to: device)
        self.glyphIndexBuffer.write(to: device)
        self.glassVertexBuffer.write(to: device)
        self.glassIndexBuffer.write(to: device)
    }

    /// Clears all vertex, index, and texture data while keeping capacity.
    public mutating func clear() {
        quadVertexBuffer.removeAll()
        quadIndexBuffer.removeAll()
        gradientVertexBuffer.removeAll()
        gradientIndexBuffer.removeAll()
        gradientUniformBuffer.removeAll()
        shaderEffectVertexBuffer.removeAll()
        shaderEffectIndexBuffer.removeAll()
        circleVertexBuffer.removeAll()
        circleIndexBuffer.removeAll()
        lineVertexBuffer.removeAll()
        lineIndexBuffer.removeAll()
        glyphVertexBuffer.removeAll()
        glyphIndexBuffer.removeAll()
        glassVertexBuffer.removeAll()
        glassIndexBuffer.removeAll()

        textures.removeAll(keepingCapacity: true)
        fontAtlases.removeAll(keepingCapacity: true)
        quadBatches.removeAll(keepingCapacity: true)
        gradientBatches.removeAll(keepingCapacity: true)
        shaderEffectBatches.removeAll(keepingCapacity: true)
        glyphBatches.removeAll(keepingCapacity: true)
        glassBatches.removeAll(keepingCapacity: true)
    }

    public var isEmpty: Bool {
        quadIndexBuffer.isEmpty
            && gradientIndexBuffer.isEmpty
            && shaderEffectIndexBuffer.isEmpty
            && circleIndexBuffer.isEmpty
            && lineIndexBuffer.isEmpty
            && glyphIndexBuffer.isEmpty
            && glassIndexBuffer.isEmpty
    }
}

// MARK: - UI Draw Pass

/// Draw pass for rendering UI primitives.
/// Note: The view uniform buffer is set by UIRenderNode, not here.
public struct UIDrawPass: DrawPass {
    public typealias Item = UITransparentRenderItem

    enum ScissorDecision: Equatable {
        case none
        case apply(Rect)
        case skipDraw
    }

    public init() {}

    public func render(
        with renderEncoder: RenderCommandEncoder,
        world: World,
        view: Entity,
        item: UITransparentRenderItem
    ) throws {
        let uiDrawData = item.drawData
        let renderBounds = resolveRenderBounds(world: world, view: view)
        let viewportOrigin = resolveViewportOrigin(world: world, view: view)

        switch resolveScissorDecision(
            clipRect: uiDrawData.clipRect,
            renderBounds: renderBounds,
            viewportOrigin: viewportOrigin,
            clipScale: world.get(Camera.self, from: view.id).map(Self.clipScale(for:)) ?? .one
        ) {
        case .none:
            break
        case let .apply(scissorRect):
            renderEncoder.setScissorRect(scissorRect)
        case .skipDraw:
            return
        }

        // Note: The uniform buffer is already set by UIRenderNode with the
        // UI-specific orthographic projection (origin at top-left)

        // Render glass quads first (they sample from the captured background, must be below UI content)
        if !uiDrawData.glassIndexBuffer.isEmpty {
            renderEncoder.setRenderPipelineState(item.renderPipeline.glassPipeline)
            renderGlass(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData,
                world: world
            )
        }

        // Render quads
        if !uiDrawData.quadIndexBuffer.isEmpty {
            renderEncoder.setRenderPipelineState(item.renderPipeline.quadPipeline)
            renderQuads(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData
            )
        }

        if !uiDrawData.gradientIndexBuffer.isEmpty {
            renderEncoder.setRenderPipelineState(item.renderPipeline.gradientPipeline)
            renderGradients(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData
            )
        }

        if !uiDrawData.shaderEffectIndexBuffer.isEmpty {
            renderShaderEffects(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData,
                world: world
            )
        }

        // Render circles
        if !uiDrawData.circleIndexBuffer.isEmpty {
            renderEncoder.setRenderPipelineState(item.renderPipeline.circlePipeline)
            renderCircles(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData
            )
        }

        // Render lines
        if !uiDrawData.lineIndexBuffer.isEmpty {
            renderEncoder.setRenderPipelineState(item.renderPipeline.linePipeline)
            renderLines(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData
            )
        }

        // Render glyphs
        if !uiDrawData.glyphIndexBuffer.isEmpty {
            renderEncoder.setRenderPipelineState(item.renderPipeline.textPipeline)
            renderGlyphs(
                renderEncoder: renderEncoder,
                uiDrawData: uiDrawData
            )
        }
    }

    // MARK: - Private Render Methods

    private func renderGlass(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData,
        world: World
    ) {
        renderEncoder.pushDebugName("UI Glass Render")
        defer { renderEncoder.popDebugName() }

        guard let glassBG = world.getResource(GlassBackgroundTexture.self) else {
            assertionFailure(
                "GlassBackgroundTexture missing on render world. Ensure UIPlugin is applied to the render subworld."
            )
            return
        }
        guard let bgTexture = glassBG.texture else {
            assertionFailure(
                "Glass background texture was never blitted. UIRenderNode should end the UI pass, blit the main target into GlassBackgroundTexture, then resume before each glass batch."
            )
            return
        }

        renderEncoder.setVertexBuffer(uiDrawData.glassVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.glassIndexBuffer, indexFormat: .uInt32)

        let resourceSet = RenderResourceSet(
            bindings: [
                RenderResourceSet.Binding(
                    binding: 0,
                    shaderStages: .fragment,
                    resource: .texture(bgTexture)
                ),
                RenderResourceSet.Binding(
                    binding: 1,
                    shaderStages: .fragment,
                    resource: .sampler(bgTexture.sampler)
                ),
            ]
        )
        renderEncoder.setResourceSet(resourceSet, index: 0)

        for batch in uiDrawData.glassBatches {
            let indexBufferOffset = batch.indexOffset * MemoryLayout<UInt32>.stride
            renderEncoder.drawIndexed(
                indexCount: batch.indexCount,
                indexBufferOffset: indexBufferOffset,
                instanceCount: 1
            )
        }
    }

    private func renderQuads(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData
    ) {
        renderEncoder.pushDebugName("UI Quad Render")
        defer { renderEncoder.popDebugName() }

        renderEncoder.setVertexBuffer(uiDrawData.quadVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.quadIndexBuffer, indexFormat: .uInt32)

        for batch in uiDrawData.quadBatches {
            guard uiDrawData.textures.indices.contains(batch.textureIndex) else {
                continue
            }

            let texture = uiDrawData.textures[batch.textureIndex]
            let resourceSet = RenderResourceSet(
                bindings: [
                    RenderResourceSet.Binding(
                        binding: 0,
                        shaderStages: .fragment,
                        resource: .texture(texture)
                    ),
                    RenderResourceSet.Binding(
                        binding: 1,
                        shaderStages: .fragment,
                        resource: .sampler(texture.sampler)
                    ),
                ]
            )
            renderEncoder.setResourceSet(resourceSet, index: 0)

            let indexBufferOffset = batch.indexOffset * MemoryLayout<UInt32>.stride
            renderEncoder.drawIndexed(
                indexCount: batch.indexCount,
                indexBufferOffset: indexBufferOffset,
                instanceCount: 1
            )
        }
    }

    private func renderGradients(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData
    ) {
        renderEncoder.pushDebugName("UI Linear Gradient Render")
        defer { renderEncoder.popDebugName() }

        renderEncoder.setVertexBuffer(uiDrawData.gradientVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.gradientIndexBuffer, indexFormat: .uInt32)

        for batch in uiDrawData.gradientBatches {
            renderEncoder.setFragmentBuffer(
                uiDrawData.gradientUniformBuffer,
                offset: batch.uniformOffset,
                slot: 0
            )

            let indexBufferOffset = batch.indexOffset * MemoryLayout<UInt32>.stride
            renderEncoder.drawIndexed(
                indexCount: batch.indexCount,
                indexBufferOffset: indexBufferOffset,
                instanceCount: 1
            )
        }
    }

    private func renderShaderEffects(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData,
        world: World
    ) {
        renderEncoder.pushDebugName("UI Shader Effect Render")
        defer { renderEncoder.popDebugName() }

        guard let renderDevice = world.getResource(RenderDeviceHandler.self)?.renderDevice else {
            return
        }

        renderEncoder.setVertexBuffer(uiDrawData.shaderEffectVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.shaderEffectIndexBuffer, indexFormat: .uInt32)

        for batch in uiDrawData.shaderEffectBatches {
            guard
                let pipeline = batch.material.getOrCreateUIShaderEffectPipeline(device: renderDevice),
                let materialData = unsafe MaterialStorage.shared.getMaterialData(for: batch.material)
            else {
                continue
            }

            renderEncoder.setRenderPipelineState(pipeline)
            setMaterialResourceSets(
                renderEncoder: renderEncoder,
                materialData: materialData
            )

            let indexBufferOffset = batch.indexOffset * MemoryLayout<UInt32>.stride
            renderEncoder.drawIndexed(
                indexCount: batch.indexCount,
                indexBufferOffset: indexBufferOffset,
                instanceCount: 1
            )
        }
    }

    private func setMaterialResourceSets(
        renderEncoder: RenderCommandEncoder,
        materialData: MaterialStorageData
    ) {
        for (groupIndex, descriptorSet) in materialData.reflectionData.descriptorSets.enumerated() {
            var bindings: [RenderResourceSet.Binding] = []

            for (_, buffer) in descriptorSet.uniformsBuffers {
                guard let uniformBuffer = materialData.uniformBufferSet[buffer.name] else {
                    continue
                }

                bindings.append(
                    RenderResourceSet.Binding(
                        binding: buffer.binding,
                        shaderStages: buffer.shaderStage,
                        resource: .uniformBuffer(uniformBuffer, offset: 0)
                    )
                )
            }

            for (_, sampler) in descriptorSet.sampledImages {
                guard let materialTexture = materialData.textures[sampler.name] else {
                    continue
                }

                bindings.append(
                    RenderResourceSet.Binding(
                        binding: sampler.binding,
                        shaderStages: sampler.shaderStage,
                        arrayLength: sampler.arraySize,
                        resource: .texture(materialTexture.texture)
                    )
                )

                if let samplerResource = materialData.reflectionData.samplers[materialTexture.samplerName] {
                    bindings.append(
                        RenderResourceSet.Binding(
                            binding: samplerResource.binding,
                            shaderStages: samplerResource.shaderStage,
                            resource: .sampler(materialTexture.texture.sampler)
                        )
                    )
                }
            }

            if !bindings.isEmpty {
                renderEncoder.setResourceSet(RenderResourceSet(bindings: bindings), index: groupIndex)
            }
        }
    }

    private func renderCircles(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData
    ) {
        renderEncoder.pushDebugName("UI Circle Render")
        defer { renderEncoder.popDebugName() }

        renderEncoder.setVertexBuffer(uiDrawData.circleVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.circleIndexBuffer, indexFormat: .uInt32)

        renderEncoder.drawIndexed(
            indexCount: uiDrawData.circleIndexBuffer.count,
            indexBufferOffset: 0,
            instanceCount: 1
        )
    }

    private func renderLines(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData
    ) {
        renderEncoder.pushDebugName("UI Line Render")
        defer { renderEncoder.popDebugName() }

        renderEncoder.setVertexBuffer(uiDrawData.lineVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.lineIndexBuffer, indexFormat: .uInt32)

        // Lines are rendered using line primitive type configured in the pipeline
        renderEncoder.drawIndexed(
            indexCount: uiDrawData.lineIndexBuffer.count,
            indexBufferOffset: 0,
            instanceCount: 1
        )
    }

    private func renderGlyphs(
        renderEncoder: RenderCommandEncoder,
        uiDrawData: UIDrawData
    ) {
        renderEncoder.pushDebugName("UI Glyph Render")
        defer { renderEncoder.popDebugName() }

        renderEncoder.setVertexBuffer(uiDrawData.glyphVertexBuffer, offset: 0, slot: 0)
        renderEncoder.setIndexBuffer(uiDrawData.glyphIndexBuffer, indexFormat: .uInt32)

        for batch in uiDrawData.glyphBatches {
            guard uiDrawData.fontAtlases.indices.contains(batch.textureIndex) else {
                continue
            }

            let texture = uiDrawData.fontAtlases[batch.textureIndex]
            let resourceSet = RenderResourceSet(
                bindings: [
                    RenderResourceSet.Binding(
                        binding: 0,
                        shaderStages: .fragment,
                        resource: .texture(texture)
                    ),
                    RenderResourceSet.Binding(
                        binding: 1,
                        shaderStages: .fragment,
                        resource: .sampler(texture.sampler)
                    ),
                ]
            )
            renderEncoder.setResourceSet(resourceSet, index: 0)

            let indexBufferOffset = batch.indexOffset * MemoryLayout<UInt32>.stride
            renderEncoder.drawIndexed(
                indexCount: batch.indexCount,
                indexBufferOffset: indexBufferOffset,
                instanceCount: 1
            )
        }
    }

    private func resolveRenderBounds(world: World, view: Entity) -> Rect? {
        if let target = world.get(RenderViewTarget.self, from: view.id), let texture = target.mainTexture {
            if texture.width > 0, texture.height > 0 {
                return Rect(x: 0, y: 0, width: Float(texture.width), height: Float(texture.height))
            }
        }

        if let windows = world.getResource(RenderWindows.self), let window = windows.windows.values.first?.value {
            let size = window.physicalSize
            if size.width > 0, size.height > 0 {
                return Rect(x: 0, y: 0, width: size.width, height: size.height)
            }
        }

        return nil
    }

    private func resolveViewportOrigin(world: World, view: Entity) -> Point {
        if let camera = world.get(Camera.self, from: view.id) {
            return camera.viewport.rect.origin
        }

        return .zero
    }

    static func clipScale(for camera: Camera) -> Vector2 {
        // Graphics contexts record clips in native display pixels. The camera's
        // render viewport may be smaller when spatial upscaling is enabled.
        let nativeSize = camera.logicalViewport.rect.size.asVector2 * camera.computedData.targetScaleFactor
        guard nativeSize.x > 0, nativeSize.y > 0 else {
            return .one
        }
        return camera.viewport.rect.size.asVector2 / nativeSize
    }

    func resolveScissorDecision(
        clipRect: Rect?,
        renderBounds: Rect?,
        viewportOrigin: Point,
        clipScale: Vector2 = .one
    ) -> ScissorDecision {
        guard let clipRect else {
            if let renderBounds {
                return .apply(renderBounds)
            }
            return .none
        }

        guard let renderBounds else {
            return .none
        }

        let adjustedClipRect = Rect(
            x: clipRect.minX * clipScale.x + viewportOrigin.x,
            y: clipRect.minY * clipScale.y + viewportOrigin.y,
            width: clipRect.width * clipScale.x,
            height: clipRect.height * clipScale.y
        )

        guard let scissorRect = clampScissorRect(adjustedClipRect, to: renderBounds) else {
            return .skipDraw
        }

        return .apply(scissorRect)
    }

    private func clampScissorRect(_ rect: Rect, to bounds: Rect) -> Rect? {
        let minX = max(bounds.minX, min(rect.minX, bounds.maxX))
        let minY = max(bounds.minY, min(rect.minY, bounds.maxY))
        let maxX = max(bounds.minX, min(rect.maxX, bounds.maxX))
        let maxY = max(bounds.minY, min(rect.maxY, bounds.maxY))

        guard maxX > minX, maxY > minY else {
            return nil
        }

        // Align to pixel boundaries to satisfy backend integer scissor validation.
        let x = minX.rounded(.down)
        let y = minY.rounded(.down)
        let width = maxX.rounded(.up) - x
        let height = maxY.rounded(.up) - y

        guard width > 0, height > 0 else {
            return nil
        }

        return Rect(x: x, y: y, width: width, height: height)
    }
}
