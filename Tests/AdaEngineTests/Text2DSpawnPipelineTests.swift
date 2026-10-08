//
//  Text2DSpawnPipelineTests.swift
//  AdaEngine
//

import AdaECS
@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
@testable import AdaRender
@testable import AdaSprite
import AdaText
import AdaTransform
import Testing

@MainActor
@Suite("Text2D spawn pipeline")
struct Text2DSpawnPipelineTests {

    @Test("text spawned from update commands is laid out in the same frame")
    func textSpawnedFromUpdateCommandsIsLaidOutInSameFrame() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let app = try await makeText2DApp()

        let entity = try #require(app.main.getEntityByName("Damage -1"))
        let textLayout = try #require(app.main.get(TextLayoutComponent.self, from: entity.id))
        let bounds = textLayout.textLayout.boundingSize()

        #expect(!textLayout.textLayout.textLines.isEmpty)
        #expect(bounds.width > 0)
        #expect(bounds.height > 0)
    }

    @Test("laid out text is extracted and prepared for rendering")
    func laidOutTextIsExtractedAndPreparedForRendering() async throws {
        try Self.setupHeadlessRenderEngineIfNeeded()

        let app = try await makeText2DApp()
        let renderWorld = World(name: "Text2DRenderWorld")
        renderWorld.addSchedulers(.extract, .preUpdate, .batching, .update)
        renderWorld
            .insertResource(MainWorld(world: app.main))
            .insertResource(RenderDeviceHandler(renderDevice: RenderEngine.shared.renderDevice))
            .insertResource(ExtractedTexts())
            .insertResource(TextDrawPass())
            .insertResource(TextBatches())
            .insertResource(TextDrawData(from: renderWorld))
            .insertResource(RenderItems<Transparent2DRenderItem>())
            .insertResource(SortedRenderItems<Transparent2DRenderItem>())
            .insertResource(RenderPipelines(configurator: TextPipeline()))

        renderWorld.spawn("Camera") {
            Camera()
            VisibleEntities()
        }

        renderWorld.addSystem(ExtractTextSystem.self, on: .extract)
        renderWorld.addSystem(PrepareTextsSystem.self, on: .preUpdate)
        renderWorld.addSystem(ClearTransparent2dRenderItemsSystem.self, on: .preUpdate)
        renderWorld.addSystem(Transparent2DBatchingSystem.self, on: .batching)
        renderWorld.addSystem(Text2DRenderSystem.self, on: .update)

        await renderWorld.runScheduler(.extract)
        #expect(try #require(renderWorld.getResource(ExtractedTexts.self)).texts.count == 1)

        await renderWorld.runScheduler(.preUpdate)
        #expect(try #require(renderWorld.getResource(RenderItems<Transparent2DRenderItem>.self)).items.count == 1)

        await renderWorld.runScheduler(.batching)
        #expect(try #require(renderWorld.getResource(SortedRenderItems<Transparent2DRenderItem>.self)).items.items.count == 1)

        await renderWorld.runScheduler(.update)
        #expect(try #require(renderWorld.getResource(TextBatches.self)).batches.count == 1)
        #expect(try #require(renderWorld.getResource(TextDrawData.self)).vertexBuffer.count > 0)
        #expect(try #require(renderWorld.getResource(TextDrawData.self)).indexBuffer.count > 0)
    }

    private func makeText2DApp() async throws -> AppWorlds {
        let app = AppWorlds(main: World())
        app
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())
            .addPlugin(TextPlugin())

        try await app.build()
        app.addSystem(SpawnText2DFromCommandsSystem.self, on: .update)
        try await app.update()
        return app
    }

    private static func setupHeadlessRenderEngineIfNeeded() throws {
        guard unsafe RenderEngine.shared == nil else {
            return
        }

        unsafe RenderEngine.configurations.preferredBackend = .headless
        try RenderEngine.setupRenderEngine()
    }
}

@PlainSystem
struct SpawnText2DFromCommandsSystem {
    @Commands
    private var commands

    init(world: World) {}

    func update(context: UpdateContext) {
        var attributes = TextAttributeContainer()
        attributes.foregroundColor = .yellow
        attributes.font = .system(size: 24)

        commands.spawn(
            "Damage -1",
            bundle: Text2D(
                textComponent: TextComponent(
                    text: AttributedText("-1", attributes: attributes)
                ),
                transform: Transform(position: [12, 34, 8])
            )
        )
    }
}
