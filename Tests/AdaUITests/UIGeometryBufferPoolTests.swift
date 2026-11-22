import AdaApp
import AdaCorePipelines
import AdaECS
import AdaText
import AdaUtils
import Math
import Testing

@testable import AdaPlatform
@_spi(Internal) import AdaRender
@testable import AdaUI

@MainActor
struct UIGeometryBufferPoolTests {
    init() throws {
        try Application.prepareForTest()
    }

    @Test
    func rebuildingTransientGeometryReusesReleasedBuffer() async throws {
        let world = makeRenderWorld()
        weak var original: (any Buffer)?
        do {
            let first = try await draw(.red, in: world)
            original = first.quadVertexBuffer.buffer
            try #require(original != nil)
        }

        let second = try await draw(.green, in: world)
        let buffer = try #require(second.quadVertexBuffer.buffer)
        #expect(buffer === original)
        #expect(second.quadVertexBuffer.elements.count == 4)
        #expect(second.quadVertexBuffer.elements.allSatisfy { $0.color == .green })
    }

    @Test
    func aPendingSubmissionAndAnotherWindowKeepTheirBuffers() async throws {
        let world = makeRenderWorld()
        let device = try #require(world.getResource(RenderDeviceHandler.self)?.renderDevice)
        let commandBuffer = device.createCommandQueue().makeCommandBuffer()
        let firstWindow = WindowID()
        let secondWindow = WindowID()
        weak var original: (any Buffer)?
        do {
            let first = try await draw(.red, for: firstWindow, in: world)
            original = first.quadVertexBuffer.buffer
            try #require(original != nil)
            commandBuffer.retainUIGeometry(first.geometryLeases)
        }

        let replacement = try await draw(.green, for: firstWindow, in: world)
        try #require(original != nil)
        #expect(replacement.quadVertexBuffer.buffer !== original)
        commandBuffer.commit()

        let other = try await draw(.blue, for: secondWindow, in: world)
        #expect(other.quadVertexBuffer.buffer === original)
        #expect(other.quadVertexBuffer.buffer !== replacement.quadVertexBuffer.buffer)
        let items = try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)?.items)
        #expect(items.count == 2)
        #expect(items.first { $0.windowId == firstWindow }?.drawData.quadVertexBuffer.elements.first?.color == .green)
    }

    @Test
    func aBorrowedRawBufferIsProtectedFromReuse() async throws {
        let world = makeRenderWorld()
        let first = try #require(try await draw(.red, in: world).quadVertexBuffer.buffer)
        let firstBytes = try await first.readData()

        let replacement = try await draw(.green, in: world)
        #expect(replacement.quadVertexBuffer.buffer !== first)
        #expect(try await first.readData() == firstBytes)
    }

    private func draw(_ color: Color, for window: WindowID? = nil, in world: World) async throws -> UIDrawData {
        var context = UIGraphicsContext()
        context.windowId = window
        context.drawRect(Rect(x: 0, y: 0, width: 20, height: 20), color: color)
        world.getRefResource(PendingUIGraphicsContext.self).graphicContexts = [context]
        world.getRefResource(UIRenderBuildState.self).needsRebuild = true
        await world.runScheduler(.update)
        let items = try #require(world.getResource(RenderItems<UITransparentRenderItem>.self)?.items)
        return try #require(items.first { $0.windowId == window }?.drawData)
    }

    private func makeRenderWorld() -> World {
        let world = World(name: "UIGeometryBufferPoolTests")
        world.setSchedulers([.extract, .prepare, .batching, .update])
        world.insertResource(RenderGraph(label: "UI buffer regression"))
        world.insertResource(RenderDeviceHandler(renderDevice: unsafe RenderEngine.shared.renderDevice))
        let app = AppWorlds(main: World())
        app.addSubworld(AppWorlds(main: world), by: .renderWorld)
        Core2DPlugin().setup(in: app)
        TextPlugin().setup(in: app)
        UIPlugin().setup(in: app)
        return world
    }
}
