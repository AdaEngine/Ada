import AdaApp
import AdaECS
import Testing

@Suite("Stereo subworld updates")
struct StereoSubworldUpdateTests {
    @Test("Rendering a second eye does not advance the game simulation again")
    @MainActor
    func secondEyeUsesSameSimulationTick() async throws {
        let app = AppWorlds(main: World())
        app.updateScheduler = .update
        app.insertResource(StereoTickCount())
        app.addSystem(StereoTickSystem.self)
        let render = AppWorlds(main: World())
        render.updateScheduler = .update
        render.insertResource(StereoTickCount())
        render.setExctractor(StereoTickExtractor())
        render.addSystem(StereoTickSystem.self)
        app.addSubworld(render, by: AppWorldName(rawValue: "StereoRender"))
        try await app.build()

        try await app.update()
        try await app.updateSubworld(by: AppWorldName(rawValue: "StereoRender"))

        #expect(app.main.getResource(StereoTickCount.self)?.value == 1)
        #expect(render.main.getResource(StereoTickCount.self)?.value == 2)
        #expect(render.main.getResource(StereoExtractedTick.self)?.value == 1)
    }
}

private struct StereoTickCount: Resource {
    var value = 0
}

private struct StereoExtractedTick: Resource {
    let value: Int
}

@PlainSystem
struct StereoTickSystem {
    @ResMut<StereoTickCount> private var count
    init(world _: World) {}
    func update(context _: UpdateContext) { count.value += 1 }
}

private struct StereoTickExtractor: WorldExctractor {
    func exctract(from mainWorld: World, to world: World) async {
        world.insertResource(StereoExtractedTick(value: mainWorld.getResource(StereoTickCount.self)?.value ?? -1))
    }
}
