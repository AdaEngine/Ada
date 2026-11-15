#if os(visionOS)
    @_spi(Internal) import AdaApp
    @_spi(Internal) import AdaAssets
    import AdaCorePipelines
    @_spi(Internal) import AdaEngine
    import AdaSpatial
    import ARKit
    import CompositorServices
    import Foundation
    import Metal
    import QuartzCore
    import Spatial
    import SwiftUI

    public enum ImmersiveRendererError: Error {
        case worldTrackingUnavailable
        case metalResourceUnavailable
        case incompatibleMetalDevice
        case missingEyeTarget
        case gpuSubmissionFailed
        case missingRasterizationRateMap
    }

    /// An embedded immersive host. The caller owns its task and cancels it when the space closes.
    /// All ECS access is on the main actor; rendering is sequential with nonblocking GPU fences.
    /// Geometry uses the compositor's foveation maps; screen-space effects consume resolved buffers.
    @available(visionOS 26.0, *)
    @MainActor
    public final class AdaImmersiveRenderer {
        /// In mixed immersion, suppress the offscreen background where no scene geometry wrote depth.
        public var preservesPassthrough = false

        public let appWorlds: AppWorlds
        public var world: World { appWorlds.main }
        public var onFrame: (@MainActor (World) -> Void)?
        /// Runs before spatial picking. A host can consume input for its own shared editor overlays.
        public var onInput: (@MainActor (World, Entity, Size) -> Void)?
        /// Supplies existing AdaUI vector feedback for the current eye. Called at a frame boundary.
        public var onDrawOverlay: (@MainActor (World, Entity, Size) -> [ImmersiveOverlayDrawing])?
        /// Rigid placement of the tracked space in scene coordinates. Configure between frames.
        /// The default preserves native tracking coordinates; editor hosts can choose an entry viewpoint.
        public var sceneFromTracking: Transform3D = .identity

        /// Latest tracked head position in scene coordinates, available after the first frame.
        public private(set) var viewerPosition: Vector3?
        private var requestedViewerPosition: Vector3?
        private var requestedViewerTranslation = Vector3.zero

        /// Places the tracked viewer at a scene position without modifying authored entity transforms.
        /// Before tracking is ready, the request is applied to the first device anchor.
        public func placeViewer(at position: Vector3) {
            requestedViewerPosition = position
        }

        /// Translates the virtual viewpoint relative to tracking. Physical head movement is preserved.
        /// Changes are applied before sampling poses on the next frame.
        public func translateViewer(by offset: Vector3) {
            guard (0..<3).allSatisfy({ offset[$0].isFinite }) else { return }
            requestedViewerTranslation += offset
        }

        private let layer: LayerRenderer
        private let tracking = ImmersiveTracking()
        private var eyes: [Entity] = []
        private var targets: [RenderTexture] = []
        private var pointers: [SpatialEventCollection.Event.ID: SpatialGrip] = [:]
        private var pointerIDs: [SpatialEventCollection.Event.ID: Int] = [:]
        private var nextPointerID = 0
        private var pendingAccess: [@MainActor (World) -> Void] = []
        private var lastTimestamp: Double?
        private var isRunning = false

        public init(layerRenderer: LayerRenderer, assetBundle: Bundle? = nil, configure: (AppWorlds) -> Void = { _ in }) {
            layer = layerRenderer
            appWorlds = AppWorlds(main: World(name: "ImmersiveMainWorld"))
            appWorlds
                .insertResource(OffscreenRenderWorld())
                .insertResource(PrimaryWindowId(windowId: RID()))
                .insertResource(SpatialInput())
                .insertResource(SpatialSelection())
                .addPlugin(MainSchedulerPlugin())
                .addPlugin(ImmersiveRenderingPlugins(assetBundle: assetBundle))
            configure(appWorlds)
        }

        /// Queues inspector edits for the next frame boundary without racing the two eye passes.
        public func performWorldAccess(_ access: @escaping @MainActor (World) -> Void) {
            pendingAccess.append(access)
        }

        /// Builds the world and renders until cancelled or the compositor invalidates the layer.
        /// `setup` runs after plugins are ready, so GPU-backed models can be instantiated there.
        public func run(setup: (World) throws -> Void = { _ in }) async throws {
            guard !isRunning else {
                return
            }
            isRunning = true
            defer {
                isRunning = false
                tracking.stop()
                layer.onSpatialEvent = { _ in }
                pointers.removeAll()
                world.insertResource(SpatialInput())
                let executionID = appWorlds.executionID
                Task { @AssetActor in AssetsManager.destroyScope(executionID) }
            }
            try await appWorlds.build()
            // Refresh pose-derived camera uniforms after transform propagation in this same frame.
            appWorlds.removeSystem(CameraSystem.self, on: .preUpdate)
            appWorlds.removeSystem(VisibilitySystem.self, on: .preUpdate)
            appWorlds.removeSystem(SpatialInteractionSystem.self, on: .update)
            world.addScheduler(Scheduler(name: .immersiveInput))
            appWorlds.addSystem(SpatialInteractionSystem.self, on: .immersiveInput)
            world.addScheduler(Scheduler(name: .immersiveViews))
            appWorlds.addSystem(CameraSystem.self, on: .immersiveViews)
            appWorlds.addSystem(VisibilitySystem.self, on: .immersiveViews)
            appWorlds.addSystem(RefreshImmersiveViewsSystem.self, on: .postUpdate)
            try appWorlds.withExecutionContext { try setup(world) }
            guard let device = unsafe RenderEngine.shared?.renderDevice else {
                throw ImmersiveRendererError.metalResourceUnavailable
            }
            let presentation = try ImmersivePresentation(
                device: device, metalDevice: layer.device,
                colorFormat: layer.configuration.colorFormat, depthFormat: layer.configuration.depthFormat,
                preservesPassthrough: preservesPassthrough
            )
            let hover = layer.configuration.trackingAreasFormat == .r16Uint
                ? try ImmersiveHoverPass(device: layer.device, format: .r16Uint, depthFormat: layer.configuration.depthFormat) : nil
            let overlay = try ImmersiveOverlayPass(device: layer.device, colorFormat: layer.configuration.colorFormat,
                depthFormat: layer.configuration.depthFormat, tracking: hover != nil)
            layer.onSpatialEvent = { [weak self] events in
                self?.receive(events)
            }
            try await tracking.start()
            let clock = LayerRenderer.Clock()
            while !Task.isCancelled, layer.state != .invalidated {
                guard layer.state == .running, let frame = layer.queryNextFrame() else {
                    lastTimestamp = nil
                    pointers.removeAll()
                    await releaseGrips()
                    try await Task.sleep(for: .milliseconds(16))
                    continue
                }
                frame.startUpdate()
                frame.endUpdate()
                guard let timing = frame.predictTiming() else { continue }
                try await clock.sleep(until: timing.optimalInputTime, tolerance: nil)
                guard layer.state != .invalidated else { break }
                frame.startSubmission()
                var submissionEnded = false
                do {
                    let drawables = frame.queryDrawables().filter { $0.target == .builtIn }
                    for drawable in drawables {
                        let timestamp = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).seconds
                        guard let anchor = tracking.world.queryDeviceAnchor(atTimestamp: timestamp), anchor.isTracked else {
                            pointers.removeAll()
                            await releaseGrips()
                            continue
                        }
                        drawable.deviceAnchor = anchor
                        let accesses = pendingAccess
                        pendingAccess.removeAll(keepingCapacity: true)
                        for access in accesses { appWorlds.withExecutionContext { access(world) } }
                        try prepareEyes(drawable, anchor: anchor)
                        let handPoses = tracking.handPoses(at: timestamp).map { hand in
                            SpatialHandPose(interactor: hand.interactor, pose: sceneFromTracking * hand.pose,
                                palmNormal: (sceneFromTracking * Vector4(hand.palmNormal, 0)).xyz.normalized, isOpen: hand.isOpen)
                        }
                        world.insertResource(SpatialTrackingFrame(
                            head: sceneFromTracking * SpatialCoordinates.fromApple(Transform3D(anchor.originFromAnchorTransform)),
                            hands: handPoses
                        ))
                        let delta = Float(min(max(timestamp - (lastTimestamp ?? timestamp - 1 / 90), 0), 0.05))
                        lastTimestamp = timestamp
                        var grips = tracking.grips(at: timestamp).map { grip in
                            SpatialGrip(interactor: grip.interactor, pose: sceneFromTracking * grip.pose, ray: grip.ray)
                        }
                        // Direct ARKit pinches own hands; system events handle only indirect input.
                        let indirect = pointers.values.map { grip in
                            SpatialGrip(interactor: grip.interactor, pose: sceneFromTracking * grip.pose,
                                ray: grip.ray.map { Ray(origin: (sceneFromTracking * Vector4($0.origin, 1)).xyz,
                                    direction: (sceneFromTracking * Vector4($0.direction, 0)).xyz.normalized) })
                        }
                        grips.removeAll { hand in indirect.contains { $0.interactor == hand.interactor } }
                        grips.append(contentsOf: indirect)
                        world.insertResource(SpatialInput(grips: grips))
                        world.insertResource(DeltaTime(deltaTime: delta))
                        if let eye = eyes.first, let target = targets.first {
                            appWorlds.withExecutionContext { onInput?(world, eye, Size(width: Float(target.size.width), height: Float(target.size.height))) }
                        }
                        await world.runScheduler(.immersiveInput)
                        var renderedEyes: [(RenderTexture, RenderTexture)] = []
                        for index in drawable.views.indices {
                            for (eyeIndex, eye) in eyes.enumerated() {
                                if var camera = eye.components[Camera.self] {
                                    camera.isActive = eyeIndex == index
                                    eye.components[Camera.self] = camera
                                }
                            }
                            if index == 0 {
                                try await appWorlds.update()
                            } else {
                                await world.runScheduler(.immersiveViews)
                                try await appWorlds.updateSubworld(by: .renderWorld)
                            }
                            guard let renderWorld = appWorlds.getSubworldBuilder(by: .renderWorld)?.main,
                                let depth = renderWorld.getEntities().first(where: {
                                    $0.components[ExtractedCameraSource.self]?.entityId == eyes[index].id
                                })?.components[RenderViewTarget.self]?.depthTexture
                            else {
                                throw ImmersiveRendererError.missingEyeTarget
                            }
                            renderedEyes.append((targets[index], depth))
                            try await presentation.finishEye()
                        }
                        appWorlds.withExecutionContext { onFrame?(world) }
                        // Dismissal can invalidate this frame while the async eye passes finish.
                        // The compositor has already retired it; do not submit/end that old frame.
                        guard layer.state != .invalidated else { break }
                        let geometry = drawable.trackingAreasTextures.isEmpty ? nil : hover?.prepare(world: world)
                        try await presentation.present(drawable, eyes: renderedEyes, buffers: geometry?.buffers ?? [], overlays: { commands, buffers in
                            if let geometry {
                                hover?.encode(commands: commands, drawable: drawable, geometry: geometry, eyes: self.eyes, nativeBuffers: buffers)
                            }
                            for (index, eye) in self.eyes.enumerated() where index < drawable.views.count {
                                let size = self.targets[index].size
                                let drawings = self.appWorlds.withExecutionContext {
                                    self.onDrawOverlay?(self.world, eye, Size(width: Float(size.width), height: Float(size.height))) ?? []
                                }
                                overlay.encode(commands: commands, drawable: drawable, eye: index, drawings: drawings)
                            }
                        }, isValid: { self.layer.state != .invalidated }) {
                            if !submissionEnded, self.layer.state != .invalidated {
                                frame.endSubmission()
                                submissionEnded = true
                            }
                        }
                    }
                    if !submissionEnded, layer.state != .invalidated { frame.endSubmission() }
                } catch {
                    if layer.state == .invalidated { break }
                    if !submissionEnded { frame.endSubmission() }
                    throw error
                }
            }
        }

        private func releaseGrips() async {
            world.insertResource(SpatialInput())
            world.removeResource(SpatialTrackingFrame.self)
            if let eye = eyes.first, let target = targets.first {
                appWorlds.withExecutionContext { onInput?(world, eye, Size(width: Float(target.size.width), height: Float(target.size.height))) }
            }
            await world.runScheduler(.immersiveInput)
            appWorlds.withExecutionContext { onFrame?(world) }
        }

        private func prepareEyes(_ drawable: LayerRenderer.Drawable, anchor: DeviceAnchor) throws {
            sceneFromTracking.origin += requestedViewerTranslation
            requestedViewerTranslation = .zero
            let head = SpatialCoordinates.fromApple(Transform3D(anchor.originFromAnchorTransform)).origin
            if let position = requestedViewerPosition {
                sceneFromTracking.origin += position - (sceneFromTracking * Vector4(head, 1)).xyz
                requestedViewerPosition = nil
            }
            viewerPosition = (sceneFromTracking * Vector4(head, 1)).xyz
            while eyes.count < drawable.views.count {
                let target = RenderTexture(size: SizeInt(width: 1, height: 1), scaleFactor: 1, format: .bgra8)
                var environment = Environment3D()
                environment.screenSpaceReflection.isEnabled = false
                let eye = world.spawn("Immersive Eye \(eyes.count)", bundle: Camera3D(camera: Camera(renderTarget: target), environment: environment))
                eyes.append(eye)
                targets.append(target)
            }
            for (index, view) in drawable.views.enumerated() {
                guard var camera = eyes[index].components[Camera.self] else { throw ImmersiveRendererError.missingEyeTarget }
                let viewport = view.textureMap.viewport
                if layer.configuration.isFoveationEnabled {
                    let textureIndex = view.textureMap.textureIndex
                    guard drawable.rasterizationRateMaps.indices.contains(textureIndex) else {
                        throw ImmersiveRendererError.missingRasterizationRateMap
                    }
                    camera.rasterizationRateMap = try MetalInterop.rasterizationRateMap(
                        drawable.rasterizationRateMaps[textureIndex],
                        layer: view.textureMap.sliceIndex,
                        reusing: camera.rasterizationRateMap
                    )
                } else {
                    camera.rasterizationRateMap = nil
                }
                camera.temporalUpscaling = nil
                let size = camera.rasterizationRateMap?.screenSize ?? SizeInt(width: max(1, Int(viewport.width)), height: max(1, Int(viewport.height)))
                if targets[index].size != size {
                    targets[index] = RenderTexture(size: size, scaleFactor: 1, format: .bgra8, debugLabel: "Immersive Eye \(index)")
                }
                camera.renderTarget = .texture(AssetHandle(targets[index]))
                camera.projection = .custom(
                    ImmersiveProjection(
                        matrix: SpatialCoordinates.fromAppleProjection(Transform3D(drawable.computeProjection(convention: .rightUpBack, viewIndex: index))),
                        near: drawable.depthRange.y,
                        far: drawable.depthRange.x
                    )
                )
                eyes[index].components[Camera.self] = camera
                eyes[index].components[Transform.self] = Transform(matrix: sceneFromTracking * SpatialCoordinates.fromApple(Transform3D(anchor.originFromAnchorTransform * view.transform)))
            }
        }

        private func receive(_ events: SpatialEventCollection) {
            for event in events {
                guard event.phase == .active else {
                    pointers[event.id] = nil
                    pointerIDs[event.id] = nil
                    continue
                }
                guard event.kind == .indirectPinch, let ray = event.selectionRay, let pose = event.inputDevicePose?.pose3D else { continue }
                if pointerIDs[event.id] == nil {
                    pointerIDs[event.id] = nextPointerID
                    nextPointerID += 1
                }
                guard let id = pointerIDs[event.id] else { continue }
                let position = Vector3(Float(pose.position.x), Float(pose.position.y), Float(pose.position.z))
                let orientation = pose.rotation.quaternion
                let applePose = Transform3D(
                    translation: position,
                    rotation: Quat(
                        x: Float(orientation.imag.x), y: Float(orientation.imag.y), z: Float(orientation.imag.z), w: Float(orientation.real)
                    ),
                    scale: .one
                )
                pointers[event.id] = SpatialGrip(
                    interactor: event.chirality.map { $0 == .left ? .leftHand : .rightHand } ?? .pointer(id),
                    pose: SpatialCoordinates.fromApple(applePose),
                    ray: Ray(
                        origin: SpatialCoordinates.fromApple(Vector3(Float(ray.origin.x), Float(ray.origin.y), Float(ray.origin.z))),
                        direction: SpatialCoordinates.fromApple(Vector3(Float(ray.direction.x), Float(ray.direction.y), Float(ray.direction.z))).normalized
                    )
                )
            }
        }
    }

    extension SchedulerName {
        static let immersiveViews: SchedulerName = "ImmersiveViews"
        static let immersiveInput: SchedulerName = "ImmersiveInput"
    }

    @System(dependencies: [.after("AdaTransform.ChildTransformSystem")])
    @MainActor
    func RefreshImmersiveViews(_ context: WorldUpdateContext) async {
        await context.world.runScheduler(.immersiveViews)
    }

    private struct ImmersiveProjection: CameraProjection {
        let matrix: Transform3D
        let near: Float
        let far: Float
        func makeClipView() -> Transform3D { matrix }
        mutating func updateView(width _: Float, height _: Float) {}
    }

    private struct ImmersiveRenderingPlugins: Plugin {
        let assetBundle: Bundle?
        func setup(in app: AppWorlds) {
            SpatialGrabbable.registerComponent()
            app.addPlugin(TransformPlugin())
                .addPlugin(InputPlugin())
                .addPlugin(RenderWorldPlugin())
                .addPlugin(EventsPlugin())
                .addPlugin(CameraPlugin())
                .addPlugin(AssetsPlugin(filePath: #filePath, assetBundle: assetBundle))
                .addPlugin(VisibilityPlugin())
                .addPlugin(ScenePlugin())
                .addPlugin(Core3DPlugin())
                .addSystem(SpatialInteractionSystem.self, on: .update)
        }
    }

    extension Duration {
        var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
    }
#endif
