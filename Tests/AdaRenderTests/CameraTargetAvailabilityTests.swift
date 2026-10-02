import AdaApp
@_spi(Internal) import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaTransform
import AdaUtils
import AdaUtilsTesting
import Math
import Testing

@Suite("Camera target availability", .serialized, .environments {
    $0.ecs.useSystemDependencies = false
})
struct CameraTargetAvailabilityTests {
    @Test("Missing windows skip repeated frames without allocating render targets")
    @MainActor
    func missingWindowSkipsFrames() async throws {
        let fixture = try Fixture(camera: Camera(window: .windowId(RID())))
        for _ in 0..<3 {
            let extracted = try await fixture.prepareFrame()
            #expect(extracted.components[Camera.self]?.isActive == false)
            #expect(extracted.components[RenderViewTarget.self]?.mainTexture == nil)
            #expect(extracted.components[RenderViewTarget.self]?.outputTexture == nil)
            #expect(fixture.source.components[Camera.self]?.isActive == true)
        }
        #expect(fixture.cache.targets.isEmpty)
    }

    @Test("Drawable loss skips rendering and a new frame resumes with cached textures")
    @MainActor
    func drawableLossAndRecovery() async throws {
        let fixture = try Fixture(camera: Camera())
        let device = unsafe RenderEngine.shared.renderDevice
        let swapchain = try #require(await device.createSwapchain(from: RID()))
        let output = RenderTexture(size: SizeInt(width: 16, height: 16), scaleFactor: 1, format: .bgra8)
        fixture.surfaces.windows[.primary] = WindowSurface(
            swapchain: swapchain,
            currentDrawable: TestDrawable(renderTexture: output)
        )
        let first = try await fixture.prepareFrame()
        let mainTexture = try #require(first.components[RenderViewTarget.self]?.mainTexture)
        #expect(first.components[Camera.self]?.isActive == true)
        #expect(first.components[RenderViewTarget.self]?.outputTexture != nil)

        fixture.surfaces.windows[.primary] = WindowSurface(swapchain: swapchain, currentDrawable: nil)
        let unavailable = try await fixture.prepareFrame()
        #expect(unavailable.components[Camera.self]?.isActive == false)
        #expect(unavailable.components[RenderViewTarget.self]?.outputTexture == nil)
        #expect(unavailable.components[RenderViewTarget.self]?.mainTexture === mainTexture)

        fixture.surfaces.windows.removeAll()
        let closed = try await fixture.prepareFrame()
        #expect(closed.components[Camera.self]?.isActive == false)
        #expect(closed.components[RenderViewTarget.self]?.outputTexture == nil)

        fixture.surfaces.windows[.primary] = WindowSurface(
            swapchain: swapchain,
            currentDrawable: TestDrawable(renderTexture: output)
        )
        let recovered = try await fixture.prepareFrame()
        #expect(recovered.components[Camera.self]?.isActive == true)
        #expect(recovered.components[RenderViewTarget.self]?.mainTexture === mainTexture)
        #expect(recovered.components[RenderViewTarget.self]?.outputTexture != nil)
        #expect(fixture.source.components[Camera.self]?.isActive == true)
    }

    @Test("Inactive cameras do not allocate targets")
    @MainActor
    func inactiveCameraSkipsPreparation() async throws {
        var camera = Camera()
        camera.isActive = false
        let fixture = try Fixture(camera: camera)
        let extracted = try await fixture.prepareFrame()
        #expect(extracted.components[RenderViewTarget.self]?.mainTexture == nil)
        #expect(fixture.cache.targets.isEmpty)
    }

    @Test("Texture cameras render without a window surface")
    @MainActor
    func textureCameraDoesNotRequireSurface() async throws {
        try Fixture.initializeRenderer()
        let texture = RenderTexture(size: SizeInt(width: 16, height: 16), scaleFactor: 1, format: .bgra8)
        let fixture = try Fixture(camera: Camera(renderTarget: texture))
        let extracted = try await fixture.prepareFrame()
        #expect(extracted.components[Camera.self]?.isActive == true)
        #expect(extracted.components[RenderViewTarget.self]?.mainTexture === texture)
        #expect(extracted.components[RenderViewTarget.self]?.outputTexture === texture)
    }
}

@MainActor
private struct Fixture {
    let main = World(name: "CameraTargetMain")
    let render = World(name: "CameraTargetRender")
    let surfaces = WindowSurfaces(windows: [:])
    let cache: Ref<ExtractedCameraRenderViewTargets>
    let source: Entity

    init(camera: Camera) throws {
        try Self.initializeRenderer()
        var camera = camera
        camera.viewport = Viewport(rect: Rect(x: 0, y: 0, width: 16, height: 16))
        source = main.spawn("SourceCamera") {
            camera
            Transform()
            VisibleEntities()
            GlobalViewUniform()
            CameraRenderGraph(subgraphLabel: "TestCameraGraph", inputSlot: "view")
        }
        main.insertResource(PrimaryWindowId(windowId: RID()))
        render.setSchedulers([.extract, .prepare])
        render.insertResource(surfaces)
        render.insertResource(ExtractedCameraRenderViewTargets())
        cache = render.getRefResource(ExtractedCameraRenderViewTargets.self)
        render.insertResource(unsafe RenderDeviceHandler(renderDevice: RenderEngine.shared.renderDevice))
        render.addSystem(ExtractCameraSystem.self, on: .extract)
        render.addSystem(ConfigurateRenderViewTargetSystem.self, on: .prepare)
    }

    static func initializeRenderer() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
    }

    func prepareFrame() async throws -> Entity {
        await RenderWorldExctractor().exctract(from: main, to: render)
        await render.runScheduler(.prepare)
        return try #require(render.getEntities().first)
    }
}

private final class TestDrawable: Drawable {
    let renderTexture: RenderTexture

    var texture: any GPUTexture { renderTexture.gpuTexture }

    init(renderTexture: RenderTexture) {
        self.renderTexture = renderTexture
    }

    func present() throws {}
}
