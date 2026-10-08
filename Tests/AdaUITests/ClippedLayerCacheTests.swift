import AdaCorePipelines
import AdaECS
@testable import AdaPlatform
@_spi(Internal) import AdaRender
import AdaText
@testable import AdaUI
import Math
import Testing

@MainActor
struct ClippedLayerCacheTests {
    init() async throws {
        try Application.prepareForTest()
    }

    @Test
    func unchangedMaskReusesBuffersAndChangedMaskRetessellates() async throws {
        let world = makeWorld()
        let layer = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 100)) { context, size in
            context.drawRect(Rect(origin: .zero, size: size), color: .red)
        }
        func context(maskWidth: Float) -> UIGraphicsContext {
            var context = UIGraphicsContext()
            let path = RoundedRectangleShape(cornerRadius: 12).path(in: Rect(x: 0, y: 0, width: maskWidth, height: 100))
            context.clip(to: path) { clipped in layer.drawLayer(in: clipped) }
            return context
        }

        let first = try await build(context(maskWidth: 100), in: world)
        let firstBuffer = try #require(first.first?.drawData.quadVertexBuffer.buffer)
        let second = try await build(context(maskWidth: 100), in: world)
        #expect(second.first?.drawData.quadVertexBuffer.buffer === firstBuffer)

        let changed = try await build(context(maskWidth: 50), in: world)
        #expect(changed.first?.drawData.quadVertexBuffer.buffer !== firstBuffer)
        let positions = changed.flatMap { $0.drawData.quadVertexBuffer.elements.map(\.position.x) }
        #expect(!positions.isEmpty)
        #expect(positions.allSatisfy { $0 <= 50.001 })
        let changedBuffer = try #require(changed.first?.drawData.quadVertexBuffer.buffer)
        let unchangedAgain = try await build(context(maskWidth: 50), in: world)
        #expect(unchangedAgain.first?.drawData.quadVertexBuffer.buffer === changedBuffer)

        layer.invalidate()
        let invalidated = try await build(context(maskWidth: 50), in: world)
        #expect(invalidated.first?.drawData.quadVertexBuffer.buffer !== changedBuffer)
    }

    @Test
    func nestedLayersKeepAllSlicesInPainterOrder() async throws {
        let world = makeWorld()
        let child = UILayer(frame: Rect(x: 20, y: 20, width: 20, height: 20)) { context, _ in
            context.drawRect(Rect(x: 20, y: 20, width: 20, height: 20), color: .green)
        }
        let parent = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 100)) { context, _ in
            context.drawRect(Rect(x: 10, y: 10, width: 20, height: 20), color: .red)
            child.drawLayer(in: context)
            context.drawRect(Rect(x: 30, y: 30, width: 20, height: 20), color: .blue)
        }
        func context() -> UIGraphicsContext {
            var context = UIGraphicsContext()
            let path = RoundedRectangleShape(cornerRadius: 8).path(in: Rect(x: 0, y: 0, width: 100, height: 100))
            context.clip(to: path) { clipped in parent.drawLayer(in: clipped) }
            return context
        }
        for _ in 0..<3 {
            let items = try await build(context(), in: world)
            #expect(items.compactMap { $0.drawData.quadVertexBuffer.elements.first?.color } == [.red, .green, .blue])
        }
    }

    @Test
    func disablingLayerCachingRetessellatesNestedContents() async throws {
        let world = makeWorld()
        let child = UILayer(frame: Rect(x: 0, y: 0, width: 30, height: 30)) { context, size in
            context.drawRect(Rect(origin: .zero, size: size), color: .green)
        }
        let parent = UILayer(frame: Rect(x: 0, y: 0, width: 100, height: 100)) { context, size in
            context.drawRect(Rect(origin: .zero, size: size), color: .blue)
            child.drawLayer(in: context)
        }
        func context() -> UIGraphicsContext {
            var context = UIGraphicsContext()
            context.allowsLayerCaching = false
            parent.drawLayer(in: context)
            return context
        }
        let first = try await build(context(), in: world)
        let second = try await build(context(), in: world)
        #expect(first.count == second.count)
        #expect(second.compactMap { $0.drawData.quadVertexBuffer.elements.first?.color } == [.blue, .green])
        #expect(first.last?.drawData.quadVertexBuffer.buffer !== second.last?.drawData.quadVertexBuffer.buffer)
        #expect(world.getResource(UILayerDrawCache.self)?.entries.isEmpty == true)
    }

    private func build(_ context: UIGraphicsContext, in world: World) async throws -> [UITransparentRenderItem] {
        var pending = PendingUIGraphicsContext()
        pending.graphicContexts.append(context)
        world.insertResource(pending)
        world.insertResource(UIRenderBuildState())
        await world.runScheduler(.update)
        return try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)).items
    }

    private func makeWorld() -> World {
        let world = World(name: "ClippedLayerCacheTests")
        world.setSchedulers([.update])
        world.insertResource(RenderDeviceHandler(renderDevice: unsafe RenderEngine.shared.renderDevice))
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
        world.insertResource(PendingUIGraphicsContext())
        world.insertResource(UIRenderBuildState())
        world.addSystem(UIRenderTesselationSystem.self)
        return world
    }
}
