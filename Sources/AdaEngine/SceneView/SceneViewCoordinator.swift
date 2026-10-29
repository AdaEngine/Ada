//
//  SceneViewCoordinator.swift
//  AdaEngine
//
//  Created by AdaEngine on 04.04.2026.
//

@_spi(Internal) import AdaApp
@_spi(Internal) import AdaAssets
import AdaAudio
import AdaCorePipelines
@_spi(Internal) import AdaECS
@_spi(Internal) import AdaInput
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUI
import AdaUtils
import Math

@MainActor
final class SceneViewCoordinator: OffscreenViewportDelegate {
    private(set) var appWorlds: AppWorlds?
    private var cameraEntity: Entity?
    private let useSceneCameras: Bool
    private var targetRenderTexture: RenderTexture?
    private var renderTexturePool: [RenderTexture] = []
    private var pendingDisplayTargets: [PendingDisplayTarget] = []
    private var retiredDisplayTargets: [RetiredDisplayTarget] = []
    private var nextRenderTextureIndex = 0
    private var frontRenderTexture: RenderTexture?
    private(set) var renderTexture: Texture2D?
    /// Frames that finished rendering and were made visible.
    private(set) var completedFrameCount = 0
    private(set) var frameSource: SceneViewFrameSource?
    var renderTextureDidChange: (@MainActor @Sendable () -> Void)?
    var renderFrameDidChange: (@MainActor @Sendable () -> Void)?

    private var isBootstrapping = false
    private var isShutdown = false
    private var hasCalledSetup = false
    /// When true, this coordinator's ``AppWorlds`` is a subworld of ``AppWorldsSession/current`` and is updated by the host ``AppWorlds/update()`` loop (no separate ``tick`` work).
    private var isHostedSubworld = false
    private weak var hostWorlds: AppWorlds?
    private var isRenderingEnabled = true
    /// Fallback when no host session exists (e.g. unusual test harnesses).
    private(set) var standaloneTickInFlight = false

    private let hostSubworldName: AppWorldName
    private var currentSize: SizeInt = .zero
    private var scaleFactor: Float = 1
    private var pendingSize: SizeInt?
    private var pendingScaleFactor: Float = 1
    private var pendingSizeElapsed: AdaUtils.TimeInterval = 0
    private var contentDeltaTime: AdaUtils.TimeInterval = 0

    private let makeClosure: @MainActor (inout AppWorlds) -> Void
    private let updateContentClosure: @MainActor (World, AdaUtils.TimeInterval) -> Void
    private let onFrameRendered: (@MainActor (Texture2D) -> Void)?
    private let prepareFramePresentation: (@MainActor () -> (@MainActor () -> Void))?
    private let frameCaptureLabel: String?
    /// `false` keeps the scene on its own update loop even when a host session exists, so it
    /// advances without the host's display link (for automation that must not depend on a visible window).
    private let joinsHostSession: Bool
    private let resizeApplyDelay: AdaUtils.TimeInterval = 0.08
    /// Common guaranteed 2D texture limit across the supported Metal and WebGPU device families.
    private let maximumRenderTextureDimension = 8_192

    private struct PendingDisplayTarget {
        var texture: RenderTexture
        var present: (@MainActor () -> Void)?
        var isPresentationPrepared = false
        var isCompleted = false
        var hasCheckedSubmission = false
    }

    private struct RetiredDisplayTarget {
        var texture: RenderTexture
        var remainingFrames: Int
    }

    init(
        useSceneCameras: Bool = false,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void,
        onFrameRendered: (@MainActor (Texture2D) -> Void)? = nil,
        prepareFramePresentation: (@MainActor () -> (@MainActor () -> Void))? = nil,
        frameCaptureLabel: String? = nil,
        joinsHostSession: Bool = true
    ) {
        self.joinsHostSession = joinsHostSession
        self.frameCaptureLabel = frameCaptureLabel
        self.useSceneCameras = useSceneCameras
        self.makeClosure = make
        self.updateContentClosure = updateContent
        self.onFrameRendered = onFrameRendered
        self.prepareFramePresentation = prepareFramePresentation
        self.hostSubworldName = AppWorldName(rawValue: "SceneView.\(UUID().uuidString)")
        if let frameCaptureLabel {
            let source = SceneViewFrameSource(label: frameCaptureLabel, coordinator: self)
            frameSource = source
            SceneViewFrameRegistry.register(source)
        }
    }

    deinit {
        let name = hostSubworldName
        let host = hostWorlds
        Task { @MainActor in
            host?.removeSubworld(by: name)
        }
    }

    /// The last frame that finished rendering. It is no longer a render target, so it is safe to read back.
    var completedFrameTexture: RenderTexture? { frontRenderTexture }

    /// Names of cameras that contribute to the frame. A display camera mirroring an authored one is included.
    var activeCameraNames: [String] {
        guard let appWorlds else { return [] }
        return appWorlds.main.getEntities()
            .filter { $0.components[Camera.self]?.isActive == true }
            .map(\.name)
            .sorted()
    }

    // MARK: - OffscreenViewportDelegate

    func bootstrapIfNeeded() {
        guard appWorlds == nil && !isBootstrapping && !isShutdown else {
            return
        }
        isBootstrapping = true

        Task { @MainActor [weak self] in
            guard let self, !self.isShutdown else {
                return
            }
            let app = self.buildAppWorlds()
            guard !self.isShutdown else {
                self.isBootstrapping = false
                return
            }
            if self.joinsHostSession, let host = AppWorldsSession.current {
                self.hostWorlds = host
                self.isHostedSubworld = true
            } else {
                self.isHostedSubworld = false
            }
            try? await app.build()
            self.configureContentScheduling(in: app)
            guard !self.isShutdown else {
                self.hostWorlds?.removeSubworld(by: self.hostSubworldName)
                self.isBootstrapping = false
                return
            }
            self.appWorlds = app
            // Visible game UI may consume every click before it reaches the
            // viewport. Install the driver before gameplay requests capture.
            // Standalone offscreen runtimes must never capture a host cursor.
            if self.isHostedSubworld, app.main.getResource(Input.self) != nil {
                app.main.getRefResource(Input.self).wrappedValue.attachPointerDriver(UIWindowManager.shared)
            }
            app.isHostedUpdateSuspended = !self.isRenderingEnabled
            self.hostWorlds?.addSubworld(app, by: self.hostSubworldName)
            self.isBootstrapping = false
            self.finalizeSetupIfReady()
        }
    }

    func shutdown() {
        releasePointerCapture()
        isShutdown = true
        frameSource.map { SceneViewFrameRegistry.unregister($0) }
        stopAudioPlaybacks()
        hostWorlds?.removeSubworld(by: hostSubworldName)
        if let executionID = appWorlds?.executionID {
            Task { @AssetActor in
                AssetsManager.destroyScope(executionID)
            }
        }
        appWorlds = nil
        cameraEntity = nil
        targetRenderTexture = nil
        renderTexturePool.removeAll()
        pendingDisplayTargets.removeAll()
        retiredDisplayTargets.removeAll()
        nextRenderTextureIndex = 0
        frontRenderTexture = nil
        renderTexture = nil
        isBootstrapping = false
        hasCalledSetup = false
        isHostedSubworld = false
        hostWorlds = nil
        standaloneTickInFlight = false
        currentSize = .zero
        scaleFactor = 1
        pendingSize = nil
        pendingScaleFactor = 1
        pendingSizeElapsed = 0
    }

    func updateSize(_ size: SizeInt, scaleFactor: Float) {
        guard size.width > 0 && size.height > 0 else {
            return
        }
        guard
            size.width <= maximumRenderTextureDimension,
            size.height <= maximumRenderTextureDimension,
            scaleFactor.isFinite,
            scaleFactor > 0
        else {
            return
        }
        guard size != currentSize || scaleFactor != self.scaleFactor else {
            pendingSize = nil
            pendingScaleFactor = 1
            pendingSizeElapsed = 0
            return
        }

        if currentSize == .zero || appWorlds == nil {
            applySize(size, scaleFactor: scaleFactor)
            return
        }

        if pendingSize != size || pendingScaleFactor != scaleFactor {
            pendingSize = size
            pendingScaleFactor = scaleFactor
            pendingSizeElapsed = 0
        }
    }

    func tick(_ deltaTime: AdaUtils.TimeInterval) {
        guard isRenderingEnabled else { return }
        applyPendingSizeIfReady(deltaTime: deltaTime)
        // GPU completion may arrive between UI extraction and submission. Only
        // swap the displayed texture and its companion UI at the next UI tick.
        publishRenderTextureIfReady()

        guard appWorlds != nil, hasCalledSetup else {
            return
        }
        // A standalone update may suspend during startup, asset loading or rendering.
        // Retargeting before it finishes reserves textures for frames that were never submitted.
        guard isHostedSubworld || !standaloneTickInFlight else { return }
        contentDeltaTime = deltaTime
        ageRetiredDisplayTargets()
        prepareNextRenderTarget()
        if isHostedSubworld {
            return
        }
        standaloneTick(deltaTime)
    }

    func setRenderingEnabled(_ enabled: Bool) {
        guard enabled != isRenderingEnabled else { return }
        isRenderingEnabled = enabled
        appWorlds?.isHostedUpdateSuspended = !enabled
    }

    func receiveInputEvent(_ event: any InputEvent) {
        guard let app = appWorlds else {
            return
        }
        guard app.main.getResource(Input.self) != nil else {
            return
        }
        let input = app.main.getRefResource(Input.self)
        input.wrappedValue.attachPointerDriver(UIWindowManager.shared)
        // Parse on the next preUpdate. Flushing during an in-flight async frame
        // lets its postUpdate cleanup discard the event before input systems see it.
        input.wrappedValue.receiveEvent(event)
    }

    func releasePointerCapture() {
        appWorlds?.main.getResource(Input.self)?.releasePointerCapture()
    }

    func updateMousePosition(_ position: Point) {
        guard let app = appWorlds else {
            return
        }
        guard app.main.getResource(Input.self) != nil else {
            return
        }
        let input = app.main.getRefResource(Input.self)
        input.wrappedValue.mousePosition = position
    }

    // MARK: - Private

    private func updateSceneContent(in world: World) {
        guard isRenderingEnabled, hasCalledSetup, !isShutdown else {
            return
        }
        // Run after input parsing and before camera preparation in preUpdate.
        updateContentClosure(world, contentDeltaTime)
        // Target eligibility is decided before simulation. Capture companion UI only
        // after this frame's input has updated the scene and its camera.
        guard let targetRenderTexture,
            let index = pendingDisplayTargets.firstIndex(where: { $0.texture === targetRenderTexture }),
            !pendingDisplayTargets[index].isPresentationPrepared else {
            return
        }
        pendingDisplayTargets[index].isPresentationPrepared = true
        pendingDisplayTargets[index].present = prepareFramePresentation?()
    }

    private func standaloneTick(_ deltaTime: AdaUtils.TimeInterval) {
        guard !standaloneTickInFlight else {
            return
        }
        standaloneTickInFlight = true
        Task { @MainActor [weak self] in
            defer { self?.standaloneTickInFlight = false }
            guard let self, let app = self.appWorlds else {
                return
            }
            app.main.insertResource(DeltaTime(deltaTime: deltaTime))
            try? await app.update()
        }
    }

    private func stopAudioPlaybacks() {
        guard let appWorlds else {
            return
        }

        for entity in appWorlds.main.getEntities() {
            entity.components[AudioComponent.self]?.playbackController.stop()
            entity.stopAllAudio()
        }
    }

    private func finalizeSetupIfReady() {
        guard
            let app = appWorlds,
            currentSize.width > 0 && currentSize.height > 0,
            !hasCalledSetup
        else {
            return
        }

        if targetRenderTexture == nil {
            rebuildRenderTexturePool(size: currentSize, scaleFactor: scaleFactor)
        }

        spawnCamera(in: app)
        hasCalledSetup = true
    }

    private func applyPendingSizeIfReady(deltaTime: AdaUtils.TimeInterval) {
        guard let pendingSize else {
            return
        }

        pendingSizeElapsed += deltaTime
        guard pendingSizeElapsed >= resizeApplyDelay else {
            return
        }

        applySize(pendingSize, scaleFactor: pendingScaleFactor)
        self.pendingSize = nil
        pendingScaleFactor = 1
        pendingSizeElapsed = 0
    }

    private func applySize(_ size: SizeInt, scaleFactor: Float) {
        currentSize = size
        self.scaleFactor = scaleFactor

        rebuildRenderTexturePool(size: size, scaleFactor: scaleFactor)

        if let entity = cameraEntity, let app = appWorlds {
            if let targetRenderTexture {
                updateCameraTarget(app: app, entity: entity, texture: targetRenderTexture)
            }
        } else {
            finalizeSetupIfReady()
        }
    }

    private func spawnCamera(in app: AppWorlds) {
        if useSceneCameras {
            if let texture = targetRenderTexture { makeCameraRenderTargetReady(texture) }
            return
        }
        guard let texture = targetRenderTexture else {
            return
        }

        let logicalSize = Size(
            width: Float(currentSize.width) / scaleFactor,
            height: Float(currentSize.height) / scaleFactor
        )
        let physicalSize = Size(
            width: Float(currentSize.width),
            height: Float(currentSize.height)
        )

        var camera = Camera(renderTarget: texture)
        camera.viewport.rect = Rect(origin: .zero, size: physicalSize)
        camera.logicalViewport.rect = Rect(origin: .zero, size: logicalSize)

        cameraEntity = app.main.spawn("SceneView_Camera") {
            camera
            GlobalViewUniform()
            VisibleEntities()
            Transform()
            Visibility.visible
            CameraRenderGraph(
                subgraphLabel: .main2D,
                inputSlot: Main2DRenderNode.InputNode.view
            )
        }
    }

    private func updateCameraTarget(app _: AppWorlds, entity: Entity, texture: RenderTexture) {
        let logicalSize = Size(
            width: Float(currentSize.width) / scaleFactor,
            height: Float(currentSize.height) / scaleFactor
        )
        let physicalSize = Size(
            width: Float(currentSize.width),
            height: Float(currentSize.height)
        )

        if var camera: Camera = entity.components[Camera.self] {
            if !useSceneCameras { camera.isActive = true }
            camera.renderTarget = .texture(AssetHandle(texture))
            camera.viewport.rect = Rect(origin: .zero, size: physicalSize)
            camera.logicalViewport.rect = Rect(origin: .zero, size: logicalSize)
            camera.projection.updateView(width: logicalSize.width, height: logicalSize.height)
            entity.components += camera
        }
    }

    private func makeCameraRenderTargetReady(_ texture: RenderTexture) {
        if useSceneCameras, let app = appWorlds {
            for entity in app.main.getEntities() where entity.components[Camera.self]?.isActive == true {
                updateCameraTarget(app: app, entity: entity, texture: texture)
            }
            return
        }
        if let entity = cameraEntity, let app = appWorlds {
            updateCameraTarget(app: app, entity: entity, texture: texture)
        }
    }

    private func rebuildRenderTexturePool(size: SizeInt, scaleFactor: Float) {
        let poolSize = max(3, unsafe RenderEngine.configurations.maxFramesInFlight + 2)
        renderTexturePool = (0..<poolSize)
            .map { index in
                let texture = RenderTexture(
                    size: size,
                    scaleFactor: scaleFactor,
                    format: .bgra8,
                    debugLabel: "SceneView_RenderTarget_\(index)"
                )
                texture.renderCompletedHandler = { [weak self] texture in
                    Task { @MainActor in
                        self?.completeRenderTexture(texture)
                    }
                }
                return texture
            }
        pendingDisplayTargets.removeAll()
        retiredDisplayTargets.removeAll()
        nextRenderTextureIndex = 0
        frontRenderTexture = nil
        // Keep presenting the last completed frame (stretched) until the first frame at the new
        // size completes. Dropping it uncovers whatever is behind the viewport, which shows up
        // as a flash on every resize (window layout, panel toggles, Play start).
        if !(renderTexture is Texture2DProxy) {
            renderTexture = nil
            renderTextureDidChange?()
        }

        if let texture = nextAvailableRenderTexture() {
            setTargetRenderTexture(texture)
        }
    }

    private func setTargetRenderTexture(_ texture: RenderTexture) {
        targetRenderTexture = texture
    }

    @discardableResult
    private func publishRenderTextureIfReady() -> Bool {
        guard !pendingDisplayTargets.isEmpty else {
            return false
        }

        var didPublish = false
        var present: (@MainActor () -> Void)?
        while let firstTarget = pendingDisplayTargets.first,
            firstTarget.isCompleted {
            let completedTarget = pendingDisplayTargets.removeFirst()
            let previousFrontTexture = frontRenderTexture
            if let currentFront = frontRenderTexture,
                currentFront !== completedTarget.texture {
                retiredDisplayTargets.append(
                    RetiredDisplayTarget(
                        texture: currentFront,
                        remainingFrames: max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
                    )
                )
            }
            frontRenderTexture = completedTarget.texture
            present = completedTarget.present
            if previousFrontTexture !== completedTarget.texture {
                didPublish = true
            }
        }
        if didPublish {
            completedFrameCount += 1
            present?()
            if let renderTexture = renderTexture as? Texture2DProxy,
                let frontRenderTexture {
                renderTexture.replaceSource(with: frontRenderTexture)
            } else if let frontRenderTexture {
                renderTexture = Texture2DProxy(source: frontRenderTexture)
                renderTextureDidChange?()
            }
            if let frontRenderTexture {
                onFrameRendered?(frontRenderTexture)
            }
            renderFrameDidChange?()
        }
        return didPublish
    }

    private func completeRenderTexture(_ texture: RenderTexture) {
        guard let index = pendingDisplayTargets.firstIndex(where: { $0.texture === texture }) else {
            return
        }

        pendingDisplayTargets[index].isCompleted = true
    }

    private func finishRenderSubmission(isCameraOutput: (RenderTexture) -> Bool) {
        // Scene navigation can replace every camera after a UI tick reserved a target.
        // That frame never renders the reservation; keeping it would block the FIFO forever.
        // Only check new reservations, preserving older targets whose GPU work is still in flight.
        pendingDisplayTargets.removeAll { pending in
            guard !pending.hasCheckedSubmission, !pending.isCompleted,
                !isCameraOutput(pending.texture) else { return false }
            // Hosts without camera extraction can drive completion themselves. Keep a target
            // that is still bound to an active scene camera in those worlds too.
            return appWorlds?.main.getEntities().contains { entity in
                guard let camera = entity.components[Camera.self], camera.isActive,
                    case let .texture(handle) = camera.renderTarget else { return false }
                return handle.asset === pending.texture
            } != true
        }
        for index in pendingDisplayTargets.indices {
            pendingDisplayTargets[index].hasCheckedSubmission = true
        }
    }

    private func prepareNextRenderTarget() {
        if let targetRenderTexture,
            !isDisplayUnavailable(targetRenderTexture) {
            makeCameraRenderTargetReady(targetRenderTexture)
            scheduleForDisplay(targetRenderTexture)
            return
        }

        guard let texture = nextAvailableRenderTexture() else {
            suspendCameraRendering()
            return
        }

        setTargetRenderTexture(texture)
        makeCameraRenderTargetReady(texture)
        scheduleForDisplay(texture)
    }

    private func suspendCameraRendering() {
        if useSceneCameras, let app = appWorlds {
            // The embedded world's primary window has no surface. Preserve authored
            // activation while skipping frames until an offscreen target is available.
            for entity in app.main.getEntities() {
                if var camera: Camera = entity.components[Camera.self] {
                    camera.renderTarget = .window(.primary)
                    entity.components += camera
                }
            }
            return
        }
        guard let cameraEntity, var camera: Camera = cameraEntity.components[Camera.self] else {
            return
        }

        camera.isActive = false
        cameraEntity.components += camera
    }

    private func scheduleForDisplay(_ texture: RenderTexture) {
        // Authored cameras may appear during the first startup scheduler. Do not leave
        // an unrendered target at the head of the presentation queue before they exist.
        if useSceneCameras,
            appWorlds?.main.getEntities().contains(where: { $0.components[Camera.self]?.isActive == true }) != true {
            return
        }
        guard !pendingDisplayTargets.contains(where: { $0.texture === texture }) else {
            return
        }

        pendingDisplayTargets.append(PendingDisplayTarget(texture: texture, present: nil))
    }

    private func nextAvailableRenderTexture() -> RenderTexture? {
        guard !renderTexturePool.isEmpty else {
            return nil
        }

        let unavailable = Set(
            (pendingDisplayTargets.map { ObjectIdentifier($0.texture) })
                + retiredDisplayTargets.map { ObjectIdentifier($0.texture) }
                + [frontRenderTexture].compactMap { $0 }.map(ObjectIdentifier.init)
        )

        for offset in 0..<renderTexturePool.count {
            let index = (nextRenderTextureIndex + offset) % renderTexturePool.count
            let texture = renderTexturePool[index]
            guard !unavailable.contains(ObjectIdentifier(texture)) else {
                continue
            }

            nextRenderTextureIndex = (index + 1) % renderTexturePool.count
            return texture
        }

        return nil
    }

    private func isDisplayUnavailable(_ texture: RenderTexture) -> Bool {
        if let frontRenderTexture, frontRenderTexture === texture {
            return true
        }
        if pendingDisplayTargets.contains(where: { $0.texture === texture }) {
            return true
        }
        if retiredDisplayTargets.contains(where: { $0.texture === texture }) {
            return true
        }
        return false
    }

    private func ageRetiredDisplayTargets() {
        for index in retiredDisplayTargets.indices {
            retiredDisplayTargets[index].remainingFrames -= 1
        }
        retiredDisplayTargets.removeAll { $0.remainingFrames <= 0 }
    }

    private func buildAppWorlds() -> AppWorlds {
        let world = World(name: "SceneView")
        var app = AppWorlds(main: world)

        makeClosure(&app)
        MainSchedulerPlugin().setup(in: app)
        app.insertResource(OffscreenRenderWorld())
        app.insertResource(PrimaryWindowId(windowId: RID()))

        return app
    }

    private func configureContentScheduling(in app: AppWorlds) {
        let target = ContentUpdateTarget(coordinator: self)
        app.insertResource(target)
        app.addSystem(ContentUpdateSystem.self, on: .preUpdate)
        if let renderWorld = app.getSubworldBuilder(by: .renderWorld) {
            renderWorld.insertResource(target)
            renderWorld.addSystem(FrameSubmissionSystem.self, on: .postUpdate)
        }
    }

    @MainActor
    private final class ContentUpdateTarget: Resource {
        weak var coordinator: SceneViewCoordinator?

        init(coordinator: SceneViewCoordinator) {
            self.coordinator = coordinator
        }
    }

    private struct FrameSubmissionSystem: System {
        @Query<Camera, RenderViewTarget> private var cameras
        @Res<ContentUpdateTarget> private var target

        var queries: SystemQueries { SystemQueries(queries: [_cameras, _target]) }

        init(world _: World) {}

        @MainActor
        func update(context _: UpdateContext) {
            target.coordinator?.finishRenderSubmission { texture in
                var isOutput = false
                cameras.forEach { camera, viewTarget in
                    if camera.isActive, viewTarget.outputTexture === texture { isOutput = true }
                }
                return isOutput
            }
        }
    }

    private struct ContentUpdateSystem: System {
        private let target: ContentUpdateTarget?
        let systemDependencies: [SystemDependency]

        // The client callback can mutate arbitrary components in this world.
        var queries: SystemQueries {
            SystemQueries(queries: [ExclusiveWorldAccess()])
        }

        init(world: World) {
            target = world.getResource(ContentUpdateTarget.self)
            let graph = world.schedulers.getScheduler(.preUpdate)?.systemGraph
            var dependencies: [SystemDependency] = []
            if graph?.containsSystem(InputEventParseSystem.self) == true {
                dependencies.append(.after(InputEventParseSystem.self))
            }
            if graph?.containsSystem(CameraSystem.self) == true {
                dependencies.append(.before(CameraSystem.self))
            }
            systemDependencies = dependencies
        }

        @MainActor
        func update(context: UpdateContext) async {
            target?.coordinator?.updateSceneContent(in: context.world)
        }
    }
}
