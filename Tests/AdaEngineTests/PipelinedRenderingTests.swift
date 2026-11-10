import AdaApp
import AdaECS
import Testing

@Suite("Pipelined subworld updates")
struct PipelinedRenderingTests {
    private static let renderName = AppWorldName(rawValue: "PipelinedRender")

    @MainActor
    private static func makeApp(pipelined: Bool?) async throws -> (app: AppWorlds, render: AppWorlds) {
        let app = AppWorlds(main: World())
        app.updateScheduler = .update
        app.insertResource(PipelineTick())
        app.addSystem(PipelineTickSystem.self)
        let render = AppWorlds(main: World())
        render.updateScheduler = .update
        render.insertResource(PipelineRenderCount())
        render.setExctractor(PipelineTickExtractor())
        render.addSystem(SlowPipelineRenderSystem.self)
        if let pipelined { render.insertResource(RenderPipelining(isEnabled: pipelined)) }
        app.addSubworld(render, by: renderName)
        try await app.build()
        return (app, render)
    }

    @Test("A pipelined subworld renders while the parent continues")
    @MainActor
    func parentDoesNotWaitForThePipelinedRender() async throws {
        let (app, render) = try await Self.makeApp(pipelined: true)
        try await app.update()
        // The parent frame finished before the slow render system did.
        #expect(render.main.getResource(PipelineRenderCount.self)?.value == 0)
        try await app.waitForPipelinedUpdates()
        #expect(render.main.getResource(PipelineRenderCount.self)?.value == 1)
        #expect(render.main.getResource(PipelineExtractedTick.self)?.value == 1)
    }

    @Test("The next extraction waits for the previous render")
    @MainActor
    func extractionIsTheOnlyMeetingPoint() async throws {
        let (app, render) = try await Self.makeApp(pipelined: true)
        try await app.update()
        try await app.update()
        // Frame 1 completed before frame 2 was extracted; frame 2 is still in flight.
        #expect(render.main.getResource(PipelineRenderCount.self)?.value == 1)
        #expect(render.main.getResource(PipelineExtractedTick.self)?.value == 2)
        try await app.waitForPipelinedUpdates()
        #expect(render.main.getResource(PipelineRenderCount.self)?.value == 2)
    }

    @Test("Tooling access waits for the render in flight")
    @MainActor
    func worldAccessIsASafePoint() async throws {
        let (app, render) = try await Self.makeApp(pipelined: true)
        try await app.update()
        let count = try await app.withWorldAccess { render.main.getResource(PipelineRenderCount.self)?.value }
        #expect(count == 1)
    }

    @Test("Subworlds stay serial unless they opt in", arguments: [nil, false] as [Bool?])
    @MainActor
    func serialIsTheDefault(setting: Bool?) async throws {
        let (app, render) = try await Self.makeApp(pipelined: setting)
        #expect(!render.isUpdatePipelined)
        try await app.update()
        #expect(render.main.getResource(PipelineRenderCount.self)?.value == 1)
    }
}

private struct PipelineTick: Resource { var value = 0 }
private struct PipelineRenderCount: Resource { var value = 0 }
private struct PipelineExtractedTick: Resource { let value: Int }

@PlainSystem
struct PipelineTickSystem {
    @ResMut<PipelineTick> private var tick
    init(world _: World) {}
    func update(context _: UpdateContext) { tick.value += 1 }
}

@PlainSystem
struct SlowPipelineRenderSystem {
    @ResMut<PipelineRenderCount> private var count
    init(world _: World) {}
    func update(context _: UpdateContext) async {
        // Long enough that the parent frame clearly finishes first.
        try? await Task.sleep(for: .milliseconds(150))
        count.value += 1
    }
}

private struct PipelineTickExtractor: WorldExctractor {
    func exctract(from mainWorld: World, to world: World) async {
        world.insertResource(PipelineExtractedTick(value: mainWorld.getResource(PipelineTick.self)?.value ?? -1))
    }
}
