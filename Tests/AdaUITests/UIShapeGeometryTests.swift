#if os(Windows)
import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaText
@testable import AdaUI
import AdaUtils
import Foundation
import Math
import Testing

@MainActor
struct UIShapeGeometryTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_GOLDEN_SAGA"] == "1"))
    func pagesSplitBetweenDrawsAndLargePathsKeepSeparateBuffers() throws {
        unsafe RenderEngine.configurations.preferredBackend = .saga
        try RenderEngine.setupRenderEngine()
        let device = unsafe RenderEngine.shared.renderDevice
        var line = UIDrawData()
        line.lineVertexBuffer.elements = UITessellator().tessellateLine(start: .zero, end: .one, lineWidth: 1, color: .blue)
        line.lineIndexBuffer.elements = [0, 1]
        var longPath = line
        longPath.lineIndexBuffer.elements = Array(repeating: [0, 1] as [UInt32], count: 128).flatMap { $0 }
        let pageSize = line.lineVertexBuffer.count * MemoryLayout<LineVertexData>.stride + 32
        var items = [line, longPath, line]
        UIShapeGeometry.upload(&items, device: device, pool: nil, pageSize: pageSize)
        let first = try #require(items[0].shapeGeometry?.storage.buffer)
        let last = try #require(items[2].shapeGeometry?.storage.buffer)
        let standalone = try #require(items[1].lineIndexBuffer.buffer)
        #expect(first !== last)
        #expect(first.length <= pageSize)
        #expect(last.length <= pageSize)
        #expect(items[1].shapeGeometry == nil)
        UIShapeGeometry.upload(&items, device: device, pool: nil)
        #expect(items[0].shapeGeometry?.storage.buffer === first)
        #expect(items[1].shapeGeometry == nil)
        #expect(items[1].lineIndexBuffer.buffer === standalone)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_GOLDEN_SAGA"] == "1"))
    func packedAndStandaloneGeometryRenderIdenticalPixelsOnVulkan() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .saga
        try RenderEngine.setupRenderEngine()
        let device = unsafe RenderEngine.shared.renderDevice
        let world = World(name: "Shape upload regression")
        world.setSchedulers([.update])
        world.insertResource(RenderDeviceHandler(renderDevice: device))
        world.insertResource(RenderPipelines(configurator: TextPipeline()))
        world.insertResource(RenderPipelines(configurator: QuadPipeline()))
        world.insertResource(RenderPipelines(configurator: CirclePipeline()))
        world.insertResource(RenderPipelines(configurator: LinePipeline()))
        world.insertResource(RenderPipelines(configurator: LinearGradientPipeline()))
        world.insertResource(RenderPipelines(configurator: GlassPipeline()))
        world.insertResource(UIRenderPipelines(from: world))
        world.insertResource(RenderItems<UITransparentRenderItem>())
        world.insertResource(UIDrawPass())
        world.insertResource(UILayerDrawCache())
        world.insertResource(UIRenderBuildState())
        world.insertResource(UIGeometryBufferPool())
        world.addSystem(UIRenderTesselationSystem.self)

        let bounds = Rect(x: 0, y: 0, width: 64, height: 64)
        var textAttributes = TextAttributeContainer()
        textAttributes.foregroundColor = .purple
        textAttributes.font = .system(size: 12)
        let label = AttributedText("Row", attributes: textAttributes)
        let layer = UILayer(frame: bounds) { context, _ in
            context.drawEllipse(in: Rect(x: 20, y: 20, width: 24, height: 24), color: .green)
            context.drawText(label, in: Rect(x: 12, y: 2, width: 40, height: 16))
        }
        var context = UIGraphicsContext()
        context.drawEllipse(in: Rect(x: 4, y: 4, width: 48, height: 48), color: .red)
        context.drawRect(Rect(x: 0, y: 0, width: 6, height: 6), color: .white)
        layer.drawLayer(in: context)
        context.pushClipRect(Rect(x: 8, y: 0, width: 40, height: 64))
        context.drawEllipse(in: Rect(x: 40, y: 8, width: 16, height: 16), color: .yellow)
        // Like AdaUI borders, lines use negative local Y below the top edge.
        context.drawLine(start: [0, -32], end: [64, -32], lineWidth: 1, color: .blue)
        context.popClipRect()
        var pending = PendingUIGraphicsContext()
        pending.graphicContexts.append(context)
        world.insertResource(pending)
        func rebuild() async throws -> [UITransparentRenderItem] {
            world.getRefResource(UIRenderBuildState.self).needsRebuild = true
            await world.runScheduler(.update)
            let items = try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)).items
            try #require(items.count == 3)
            return items
        }

        let first = try await rebuild()
        let items = try await rebuild()
        try #require(!items[0].drawData.quadIndexBuffer.isEmpty)
        try #require(!items[1].drawData.glyphIndexBuffer.isEmpty)
        #expect(items[0].drawData.quadIndexBuffer.buffer == nil)
        #expect(items[1].drawData.glyphIndexBuffer.buffer == nil)
        let root = try #require(items[0].drawData.shapeGeometry?.storage.buffer)
        let leaf = try #require(items[1].drawData.shapeGeometry?.storage.buffer)
        #expect(items[2].drawData.shapeGeometry?.storage.buffer === root)
        #expect(first[1].drawData.shapeGeometry?.storage.buffer === leaf)
        #expect(leaf !== root)
        #expect(first[0].drawData.shapeGeometry?.storage.buffer !== root)

        func render(_ items: [UITransparentRenderItem]) async throws -> Image {
            let target = RenderTexture(size: SizeInt(width: 64, height: 64), scaleFactor: 1, format: .bgra8)
            var viewTarget = RenderViewTarget()
            viewTarget.mainTexture = target
            let view = world.spawn { viewTarget }
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
            ]))
            let projection = Transform3D.createUIProjection(width: bounds.width, height: bounds.height)
            pass.setViewport(bounds)
            pass.setVertexBuffer(GlobalViewUniform(projectionMatrix: projection, viewProjectionMatrix: projection), slot: GlobalBufferIndex.viewUniform)
            for item in items {
                try UIDrawPass().render(with: pass, world: world, view: view, item: item)
            }
            pass.endRenderPass()
            command.commit()
            return try #require(try await device.readImage(from: target))
        }
        let packed = try await render(items)
        let reference = try await render(items.map { item in
            var standalone = item
            standalone.drawData.write(to: device)
            return standalone
        })
        #expect(packed.data == reference.data)
        let colors = Set((0..<64).flatMap { y in (0..<64).map { packed.getPixel(x: $0, y: y) } })
        #expect(colors.contains(.red))
        #expect(colors.contains(.green))
        #expect(colors.contains(.blue))
        #expect(colors.contains(.yellow))
        #expect(colors.contains(.white))
        #expect(colors.contains { $0.red > 0.25 && $0.blue > 0.25 && $0.red > $0.green && $0.blue > $0.green })
    }
}
#endif
