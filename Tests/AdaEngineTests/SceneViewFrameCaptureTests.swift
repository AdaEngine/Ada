import Testing
@_spi(Internal) import AdaRender
@testable import AdaEngine

@MainActor
@Suite("SceneView frame capture", .serialized)
struct SceneViewFrameCaptureTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SceneViewFrameCaptureTests")))
        }
    }

    @Test
    func sceneCamera3DFrameIsReadFromTheGameCamera() async throws {
        let coordinator = SceneViewCoordinator(
            useSceneCameras: true,
            make: { app in
                var camera = Camera()
                camera.projection = .perspective(PerspectiveProjection())
                app.main.spawn("Camera") {
                    camera
                    Transform()
                }
            },
            updateContent: { _, _ in },
            frameCaptureLabel: "game"
        )
        defer { coordinator.shutdown() }
        let source = try #require(coordinator.frameSource)
        source.pixelReader = { _ in Image(width: 32, height: 16, color: .red, format: .bgra8) }

        try await boot(coordinator)
        #expect(SceneViewFrameRegistry.latest(label: "game") === source)
        #expect(throws: SceneViewFrameCaptureError.noCompletedFrame) { try source.captureFrame() }

        try await completeFrame(of: coordinator)
        let frame = try source.captureFrame(cameraName: "Camera")
        #expect(frame.sequence == 1)
        #expect(frame.sourceWidth == 32)
        #expect(frame.sourceHeight == 16)
        #expect(frame.activeCameras == ["Camera"])
        #expect(source.activeCameras.map(\.name) == ["Camera"])
    }

    @Test
    func defaultCamera2DFrameIsReadWithoutAuthoredCamera() async throws {
        let coordinator = SceneViewCoordinator(make: { _ in }, updateContent: { _, _ in }, frameCaptureLabel: "game")
        defer { coordinator.shutdown() }
        let source = try #require(coordinator.frameSource)
        source.pixelReader = { _ in Image(width: 8, height: 8, color: .blue, format: .bgra8) }

        try await boot(coordinator)
        try await completeFrame(of: coordinator)
        let frame = try source.captureFrame(cameraName: "SceneView_Camera")
        #expect(frame.activeCameras == ["SceneView_Camera"])
        #expect(frame.image.width == 8)
    }

    @Test
    func unknownCameraAndUnreadablePixelsAreExplicitErrors() async throws {
        let coordinator = SceneViewCoordinator(
            useSceneCameras: true,
            make: { app in app.main.spawn("Camera") { Camera() } },
            updateContent: { _, _ in },
            frameCaptureLabel: "game"
        )
        defer { coordinator.shutdown() }
        let source = try #require(coordinator.frameSource)
        try await boot(coordinator)
        try await completeFrame(of: coordinator)

        // The headless backend cannot read pixels back.
        #expect(throws: SceneViewFrameCaptureError.frameUnreadable) { try source.captureFrame() }

        source.pixelReader = { _ in Image(width: 4, height: 4, color: .white, format: .bgra8) }
        #expect(throws: SceneViewFrameCaptureError.cameraUnavailable(name: "Missing", activeCameras: ["Camera"])) {
            try source.captureFrame(cameraName: "Missing")
        }
    }

    @Test
    func largeFramesAreDownscaledToTheRequestedDimension() async throws {
        let coordinator = SceneViewCoordinator(make: { _ in }, updateContent: { _, _ in }, frameCaptureLabel: "game")
        defer { coordinator.shutdown() }
        let source = try #require(coordinator.frameSource)
        source.pixelReader = { _ in Image(width: 400, height: 200, color: .green, format: .bgra8) }
        try await boot(coordinator)
        try await completeFrame(of: coordinator)

        let frame = try source.captureFrame(maxDimension: 100)
        #expect(frame.image.width == 100)
        #expect(frame.image.height == 50)
        #expect(frame.image.data.count == 100 * 50 * 4)
        #expect(frame.sourceWidth == 400)
        let unscaled = try source.captureFrame(maxDimension: 4_000)
        #expect(unscaled.image.width == 400)
    }

    @Test
    func waitingForANewFrameTimesOutAndStoppedViewsDisappear() async throws {
        let coordinator = SceneViewCoordinator(make: { _ in }, updateContent: { _, _ in }, frameCaptureLabel: "game")
        let source = try #require(coordinator.frameSource)
        source.pixelReader = { _ in Image(width: 4, height: 4, color: .white, format: .bgra8) }
        try await boot(coordinator)
        try await completeFrame(of: coordinator)

        await #expect(throws: SceneViewFrameCaptureError.timeout) {
            _ = try await source.captureFrame(after: source.frameSequence, timeout: .milliseconds(60))
        }
        coordinator.shutdown()
        #expect(SceneViewFrameRegistry.sources.contains { $0 === source } == false)
    }

    @Test
    func resizeKeepsPresentingTheLastFrameInsteadOfBlanking() async throws {
        var now = ContinuousClock.now
        let coordinator = SceneViewCoordinator(
            make: { _ in },
            updateContent: { _, _ in },
            frameCaptureLabel: "game",
            resizeClock: { now }
        )
        defer { coordinator.shutdown() }
        try await boot(coordinator)
        try await completeFrame(of: coordinator)
        let displayed = try #require(coordinator.renderTexture)

        coordinator.updateSize(SizeInt(width: 32, height: 24), scaleFactor: 1)
        coordinator.tick(0.2)
        for _ in 0..<5000 where coordinator.standaloneTickInFlight { await Task.yield() }

        // A large delta measured before the resize request must not trigger reallocation.
        let app = try #require(coordinator.appWorlds)
        #expect(renderTarget(in: app.main)?.width == 16)
        now = now.advanced(by: .milliseconds(70))
        coordinator.updateSize(SizeInt(width: 36, height: 26), scaleFactor: 1)
        now = now.advanced(by: .milliseconds(79))
        coordinator.tick(0.2)
        for _ in 0..<5000 where coordinator.standaloneTickInFlight { await Task.yield() }
        #expect(renderTarget(in: app.main)?.width == 16)
        now = now.advanced(by: .milliseconds(1))
        coordinator.tick(0.016)
        for _ in 0..<5000 where coordinator.standaloneTickInFlight { await Task.yield() }

        // The viewport must never expose what is behind it (a white flash) while the new targets render.
        #expect(coordinator.renderTexture === displayed)
        #expect(coordinator.completedFrameTexture == nil)
        let target = try #require(renderTarget(in: app.main))
        #expect(target.width == 36)
        target.notifyRenderCompleted()
        for _ in 0..<50 { await Task.yield() }
        coordinator.tick(0.016)
        for _ in 0..<5000 where coordinator.standaloneTickInFlight { await Task.yield() }
        #expect(coordinator.renderTexture === displayed)
        #expect(displayed.width == 36)
    }

    @Test
    func asynchronousBackendsCanReadCompletedFrames() async throws {
        let coordinator = SceneViewCoordinator(make: { _ in }, updateContent: { _, _ in }, frameCaptureLabel: "async")
        defer { coordinator.shutdown() }
        let source = try #require(coordinator.frameSource)
        source.asyncPixelReader = { _ in
            await Task.yield()
            return Image(width: 20, height: 10, color: .green, format: .bgra8)
        }
        try await boot(coordinator)
        try await completeFrame(of: coordinator)
        let sequence = source.frameSequence
        let frame = try await source.captureFrame(after: 0, maxDimension: 10)
        #expect(frame.sequence == sequence)
        #expect(frame.sourceWidth == 20)
        #expect(frame.sourceHeight == 10)
        #expect(frame.image.width == 10)
        #expect(frame.image.height == 5)
    }

    @Test
    func viewsWithoutALabelAreNotCapturable() async throws {
        let coordinator = SceneViewCoordinator(make: { _ in }, updateContent: { _, _ in })
        defer { coordinator.shutdown() }
        #expect(coordinator.frameSource == nil)
    }

    private func renderTarget(in world: World) -> RenderTexture? {
        for entity in world.getEntities() {
            if case let .texture(handle)? = entity.components[Camera.self]?.renderTarget {
                return handle.asset
            }
        }
        return nil
    }

    private func boot(_ coordinator: SceneViewCoordinator) async throws {
        coordinator.bootstrapIfNeeded()
        for _ in 0..<500 where coordinator.appWorlds == nil {
            await Task.yield()
        }
        _ = try #require(coordinator.appWorlds)
        coordinator.updateSize(SizeInt(width: 16, height: 16), scaleFactor: 1)
    }

    /// Submits one frame to the render target and reports its GPU completion.
    private func completeFrame(of coordinator: SceneViewCoordinator) async throws {
        coordinator.tick(0.016)
        for _ in 0..<5000 where coordinator.standaloneTickInFlight { await Task.yield() }
        let app = try #require(coordinator.appWorlds)
        let target = try #require(renderTarget(in: app.main))
        target.notifyRenderCompleted()
        for _ in 0..<50 { await Task.yield() }
        coordinator.tick(0.016)
        for _ in 0..<5000 where coordinator.standaloneTickInFlight { await Task.yield() }
    }
}
