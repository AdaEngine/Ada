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
    }

    /// An embedded immersive host. The caller owns its task and cancels it when the space closes.
    /// All ECS access is on the main actor; rendering is sequential with nonblocking GPU fences.
    /// This initial path prioritizes correctness over throughput and does not enable foveation.
    @available(visionOS 26.0, *)
    @MainActor
    public final class AdaImmersiveRenderer {
        public let appWorlds: AppWorlds
        public var world: World { appWorlds.main }
        public var onFrame: (@MainActor (World) -> Void)?

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
            guard let device = unsafe RenderEngine.shared?.renderDevice,
                let queue = MetalInterop.commandQueue(for: device)
            else {
                throw ImmersiveRendererError.metalResourceUnavailable
            }
            guard queue.device.registryID == layer.device.registryID else { throw ImmersiveRendererError.incompatibleMetalDevice }
            let presentation = try ImmersivePresentation(
                queue: queue, colorFormat: layer.configuration.colorFormat, depthFormat: layer.configuration.depthFormat
            )
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
                        for access in accesses { access(world) }
                        try prepareEyes(drawable, anchor: anchor)
                        let delta = Float(min(max(timestamp - (lastTimestamp ?? timestamp - 1 / 90), 0), 0.05))
                        lastTimestamp = timestamp
                        var grips = tracking.grips(at: timestamp)
                        // Direct ARKit pinches own hands; system events handle only indirect input.
                        let indirect = Array(pointers.values)
                        grips.removeAll { hand in indirect.contains { $0.interactor == hand.interactor } }
                        grips.append(contentsOf: indirect)
                        world.insertResource(SpatialInput(grips: grips))
                        world.insertResource(DeltaTime(deltaTime: delta))
                        await world.runScheduler(.immersiveInput)
                        var renderedEyes: [(RenderTexture, RenderTexture)] = []
                        for index in eyes.indices {
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
                        onFrame?(world)
                        try await presentation.present(drawable, eyes: renderedEyes) {
                            frame.endSubmission()
                            submissionEnded = true
                        }
                    }
                    if !submissionEnded { frame.endSubmission() }
                } catch {
                    if !submissionEnded { frame.endSubmission() }
                    throw error
                }
            }
        }

        private func releaseGrips() async {
            world.insertResource(SpatialInput())
            await world.runScheduler(.immersiveInput)
            onFrame?(world)
        }

        private func prepareEyes(_ drawable: LayerRenderer.Drawable, anchor: DeviceAnchor) throws {
            while eyes.count < drawable.views.count {
                let target = RenderTexture(size: SizeInt(width: 1, height: 1), scaleFactor: 1, format: .bgra8)
                var environment = Environment3D()
                environment.screenSpaceReflection.isEnabled = false
                let eye = world.spawn("Immersive Eye \(eyes.count)", bundle: Camera3D(camera: Camera(renderTarget: target), environment: environment))
                eyes.append(eye)
                targets.append(target)
            }
            for (index, view) in drawable.views.enumerated() {
                let viewport = view.textureMap.viewport
                let size = SizeInt(width: max(1, Int(viewport.width)), height: max(1, Int(viewport.height)))
                if targets[index].size != size {
                    targets[index] = RenderTexture(size: size, scaleFactor: 1, format: .bgra8, debugLabel: "Immersive Eye \(index)")
                }
                guard var camera = eyes[index].components[Camera.self] else { throw ImmersiveRendererError.missingEyeTarget }
                camera.renderTarget = .texture(AssetHandle(targets[index]))
                camera.projection = .custom(
                    ImmersiveProjection(
                        matrix: SpatialCoordinates.fromAppleProjection(Transform3D(drawable.computeProjection(convention: .rightUpBack, viewIndex: index))),
                        near: drawable.depthRange.y,
                        far: drawable.depthRange.x
                    )
                )
                eyes[index].components[Camera.self] = camera
                eyes[index].components[Transform.self] = Transform(matrix: SpatialCoordinates.fromApple(Transform3D(anchor.originFromAnchorTransform * view.transform)))
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
                        direction: SpatialCoordinates.fromApple(Vector3(Float(ray.direction.x), Float(ray.direction.y), Float(ray.direction.z)))
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
