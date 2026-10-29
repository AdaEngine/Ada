@_spi(Internal) import AdaApp
@_spi(Internal) import AdaAssets
import AdaAudio
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math
import Synchronization

/// A frame on the movie's simulation timeline. Warmup frames have negative indices.
public struct MovieFrame: Resource, Sendable {
    public let index: Int
    public let framesPerSecond: Int
    public var time: Double { Double(index) / Double(framesPerSecond) }
    public var deltaTime: AdaUtils.TimeInterval { 1 / AdaUtils.TimeInterval(framesPerSecond) }
    public var isWarmup: Bool { index < 0 }
}

/// Records a fresh game world at a fixed simulation rate, waiting for every GPU
/// frame and disk write before advancing. Rendering speed never drops movie frames.
/// Configure the same gameplay plugins and cameras as your game in `make`.
/// Platform/window plugins are unnecessary for this offscreen runtime.
@MainActor
public final class MovieMaker {
    public private(set) var isRecording = false
    public private(set) var recordedFrameCount = 0
    private var stopRequested = false

    public init() {}

    /// Ends the take after the current frame has been written and finalizes its WAV and manifest.
    public func stop() { stopRequested = true }

    /// `update` runs before each simulation step, for camera choreography or scripted input.
    /// `progress` runs after each saved frame. Cancellation preserves the completed frames.
    @discardableResult
    public func record(
        configuration: MovieRecordingConfiguration,
        make: @MainActor (AppWorlds) async throws -> Void,
        update: @MainActor (World, MovieFrame) async throws -> Void = { _, _ in },
        progress: @MainActor (Int) -> Void = { _ in }
    ) async throws -> MovieRecording {
        guard !isRecording else { throw MovieMakerError.recordingInProgress }
        try configuration.validate()
        isRecording = true
        stopRequested = false
        recordedFrameCount = 0
        defer { isRecording = false }
        let audio = try OfflineAudioRenderer()
        let writer = try MovieSequenceWriter(configuration: configuration)
        let app = AppWorlds(main: World(name: "MovieMaker"))
        MainSchedulerPlugin().setup(in: app)
        EventsPlugin().setup(in: app)
        app.insertResource(OffscreenRenderWorld())
        app.insertResource(PrimaryWindowId(windowId: RID()))

        return try await AudioServer.$offlineServer.withValue(audio.server) {
            do {
                try await app.withExecutionContext {
                    try await make(app)
                    try await app.build()
                }
                guard let renderWorld = app.getSubworldBuilder(by: .renderWorld),
                      renderWorld.main.getResource(ExtractedCameraRenderViewTargets.self) != nil else {
                    throw MovieMakerError.missingRenderWorld
                }
                let capture = MovieCaptureTarget(configuration: configuration)
                let graph = renderWorld.getRefResource(RenderGraph.self)
                let completion = capture.completion
                graph.wrappedValue.addFrameCompletionHandler { completion.completed.withLock { $0 = true } }
                let captureScheduler = SchedulerName(rawValue: "MovieCapture")
                app.main.addScheduler(Scheduler(name: captureScheduler))
                let order = app.main.getResource(DefaultSchedulerOrder.self)?.order ?? []
                app.insertResource(DefaultSchedulerOrder(order: order + [captureScheduler]))
                app.insertResource(capture)
                app.addSystem(MovieCaptureCameraSystem.self, on: captureScheduler)

                try await SimulationClock.$fixedDeltaTime.withValue(1 / AdaUtils.TimeInterval(configuration.framesPerSecond)) {
                    for index in -configuration.warmupFrameCount..<configuration.frameCount {
                        try Task.checkCancellation()
                        if stopRequested { break }
                        let frame = MovieFrame(index: index, framesPerSecond: configuration.framesPerSecond)
                        app.insertResource(frame)
                        try await app.withExecutionContext {
                            try await update(app.main, frame)
                        }
                        capture.completion.completed.withLock { $0 = false }
                        try await app.update()
                        guard capture.activeCameraCount > 0 else { throw MovieMakerError.noActiveCamera }
                        try await capture.waitForCompletion(timeout: configuration.frameTimeout)
                        // The mixer advances even during warmup and silent takes.
                        let samples = try audio.render(frameCount: OfflineAudioRenderer.sampleRate / configuration.framesPerSecond)
                        if frame.isWarmup { continue }
                        guard let image = unsafe try await RenderEngine.shared.renderDevice.readImage(from: capture.texture),
                              image.width == configuration.width, image.height == configuration.height,
                              !image.data.isEmpty else { throw MovieMakerError.unreadableFrame }
                        try await writer.append(image: image, samples: samples)
                        recordedFrameCount += 1
                        progress(recordedFrameCount)
                    }
                }
                let recording = try await writer.finish(status: .completed)
                await cleanup(app)
                return recording
            } catch {
                // A cancelled or failed take still has a readable WAV and an accurate manifest.
                _ = try? await writer.finish(status: error is CancellationError ? .cancelled : .failed)
                await cleanup(app)
                throw error
            }
        }
    }

    private func cleanup(_ app: AppWorlds) async {
        try? app.main.getResource(AudioServer.self)?.stop()
        await AssetsManager.destroyScope(app.executionID)
    }
}

@MainActor
private final class MovieCaptureTarget: Resource {
    let texture: RenderTexture
    let completion = MovieFrameCompletion()
    var activeCameraCount = 0

    init(configuration: MovieRecordingConfiguration) {
        texture = RenderTexture(
            size: SizeInt(width: configuration.width, height: configuration.height),
            scaleFactor: 1,
            format: .bgra8,
            debugLabel: "MovieMaker"
        )
    }

    func waitForCompletion(timeout: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !completion.completed.withLock({ $0 }) {
            guard clock.now < deadline else { throw MovieMakerError.frameTimeout }
            try await Task.sleep(for: .milliseconds(1))
        }
    }
}

private final class MovieFrameCompletion: Sendable {
    let completed = Mutex(false)
}

/// Runs after all simulation schedulers, including transform propagation and camera cuts.
private struct MovieCaptureCameraSystem: System {
    @Query<Entity, Ref<Camera>, GlobalTransform, CameraRenderGraph> private var cameras
    @Res<MovieCaptureTarget> private var target
    var queries: SystemQueries { SystemQueries(queries: [_cameras, _target]) }
    init(world _: World) {}

    @MainActor
    func update(context: UpdateContext) {
        target.activeCameraCount = 0
        var uniforms: [(Entity, GlobalViewUniform)] = []
        cameras.forEach { entity, camera, transform, _ in
            guard camera.isActive else { return }
            camera.renderTarget = .texture(AssetHandle(target.texture))
            let uniform = CameraSystem.refreshView(of: camera, globalTransform: transform, primaryWindow: nil)
            uniforms.append((entity, uniform))
            target.activeCameraCount += 1
        }
        for (entity, uniform) in uniforms { entity.components += uniform }
    }
}
