@testable import AdaApp
import AdaECS
import Testing

@MainActor
@Suite("App world deferred removal")
struct AppWorldDeferredRemovalTests {
    @Test("Removals requested after the main scheduler survive frame completion")
    func removesEntityDuringSubworldUpdate() async throws {
        let app = AppWorlds(main: World(name: "WindowRemovalMain"))
        MainSchedulerPlugin().setup(in: app)
        let camera = app.spawn("SettingsWindowCamera")

        let subworld = AppWorlds(main: World(name: "WindowRemovalRender"))
        MainSchedulerPlugin().setup(in: subworld)
        subworld.setExctractor(RemoveCameraDuringExtraction(cameraID: camera.id))
        app.addSubworld(subworld, by: AppWorldName(rawValue: "WindowRemovalRender"))
        try await app.build()

        try await app.update()
        #expect(app.main.getEntityByID(camera.id) == nil)
        try await app.update()
        #expect(app.main.getEntityByID(camera.id) == nil)
    }

    @Test("Paused worlds still apply pending lifecycle removals")
    func removesEntityWhilePaused() async throws {
        let app = AppWorlds(main: World(name: "PausedWindowRemoval"))
        MainSchedulerPlugin().setup(in: app)
        app.insertResource(SimulationControl(mode: .paused))
        let camera = app.spawn("SettingsWindowCamera")
        try await app.build()

        camera.removeFromWorld()
        try await app.update()
        #expect(app.main.getEntityByID(camera.id) == nil)
    }
}

private struct RemoveCameraDuringExtraction: WorldExctractor {
    let cameraID: Entity.ID

    func exctract(from mainWorld: World, to _: World) async {
        mainWorld.getEntityByID(cameraID)?.removeFromWorld()
    }
}
