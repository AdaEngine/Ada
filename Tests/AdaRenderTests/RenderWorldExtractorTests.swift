import AdaApp
@_spi(Internal) import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaUtils
import Math
import Testing

@Suite("Render World Extractor Tests")
struct RenderWorldExtractorTests {
    @Test("Offscreen rendering leaves host windows to the window renderer")
    @MainActor
    func offscreenRenderingDoesNotAcquireWindowSurfaces() async throws {
        unsafe RenderEngine.configurations.preferredBackend = .headless
        let app = AppWorlds(main: World(name: "WindowSurfaceTest"))
        app.addPlugin(RenderWorldPlugin())
        MainSchedulerPlugin().setup(in: app)
        let primaryID = RID()
        app.insertResource(PrimaryWindowId(windowId: primaryID))
        try await app.build()

        let engine = try #require(unsafe RenderEngine.shared)
        try engine.createWindow(primaryID, for: TestRenderSurface(), size: SizeInt(width: 16, height: 16))
        defer { try? engine.destroyWindow(primaryID) }
        let secondaryID = RID()
        try #require(primaryID != secondaryID)
        try engine.createWindow(secondaryID, for: TestRenderSurface(), size: SizeInt(width: 16, height: 16))
        defer { try? engine.destroyWindow(secondaryID) }

        try await app.update()
        let renderWorld = try #require(app.getSubworldBuilder(by: .renderWorld))
        let surfaces = try #require(renderWorld.main.getResource(WindowSurfaces.self))
        #expect(surfaces.windows[.primary] != nil)
        #expect(surfaces.windows[.windowId(secondaryID)] != nil)

        let offscreenApp = AppWorlds(main: World(name: "OffscreenSurfaceTest"))
        offscreenApp.addPlugin(RenderWorldPlugin())
        MainSchedulerPlugin().setup(in: offscreenApp)
        offscreenApp.insertResource(PrimaryWindowId(windowId: RID()))
        offscreenApp.insertResource(OffscreenRenderWorld())
        try await offscreenApp.build()
        app.addSubworld(offscreenApp, by: AppWorldName(rawValue: "OffscreenSurfaceTest"))
        try await app.update()
        let offscreenRenderWorld = try #require(offscreenApp.getSubworldBuilder(by: .renderWorld))
        let offscreenSurfaces = try #require(offscreenRenderWorld.main.getResource(WindowSurfaces.self))
        #expect(offscreenSurfaces.windows.isEmpty)
        #expect(surfaces.windows[.primary] != nil)
        #expect(surfaces.windows[.windowId(secondaryID)] != nil)
        #expect(try engine.getRenderWindows().windows.firstValue(for: primaryID) != nil)
        #expect(try engine.getRenderWindows().windows.firstValue(for: secondaryID) != nil)
    }

    @Test("Extraction mirrors primary window id into render world")
    func extractionMirrorsPrimaryWindowIdIntoRenderWorld() async {
        let mainWorld = World(name: "MainWorld")
        let renderWorld = World(name: "RenderWorld")
        let windowId = RID()

        renderWorld.setSchedulers([.extract])
        mainWorld.insertResource(PrimaryWindowId(windowId: windowId))

        await RenderWorldExctractor().exctract(from: mainWorld, to: renderWorld)

        #expect(renderWorld.getResource(PrimaryWindowId.self)?.windowId == windowId)
    }

    @Test("Explicit primary window id resolves to primary surface")
    func explicitPrimaryWindowIdResolvesToPrimarySurface() {
        let windowId = RID()
        let surfaces = WindowSurfaces(windows: [:])
        surfaces.windows[.primary] = WindowSurface(swapchain: nil, currentDrawable: nil)

        let resolvedSurface = resolveWindowSurface(
            for: .windowId(windowId),
            in: surfaces,
            primaryWindow: PrimaryWindowId(windowId: windowId)
        )

        #expect(resolvedSurface != nil)
    }

    @Test("Unregistered non-primary window id has no surface")
    func unregisteredNonPrimaryWindowIdHasNoSurface() {
        let requestedWindowId = RID()
        var primaryWindowId = RID()
        while primaryWindowId == requestedWindowId {
            primaryWindowId = RID()
        }

        let surfaces = WindowSurfaces(windows: [:])
        surfaces.windows[.primary] = WindowSurface(swapchain: nil, currentDrawable: nil)

        let resolvedSurface = resolveWindowSurface(
            for: .windowId(requestedWindowId),
            in: surfaces,
            primaryWindow: PrimaryWindowId(windowId: primaryWindowId)
        )

        #expect(resolvedSurface == nil)
    }
}

@MainActor
private struct TestRenderSurface: RenderSurface {
    var scaleFactor: Float { 1 }
    var prefferedPixelFormat: PixelFormat { .bgra8 }
}
