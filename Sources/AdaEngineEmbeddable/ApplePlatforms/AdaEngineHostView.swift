//
//  AdaEngineHostView.swift
//  AdaEngine
//

#if canImport(MetalKit) && canImport(UIKit)
    import AdaEngine
    import MetalKit
    import UIKit

    /// A UIKit view that runs an AdaEngine world inside an existing application.
    ///
    /// Unlike the regular application runner, this host owns only its render view
    /// and frame loop. It never creates another `UIApplication` or native window.
    @MainActor
    public final class AdaEngineHostView: MetalView {
        public typealias ReadyHandler = @MainActor (AppWorlds) -> Void

        /// The worlds rendered by this host.
        public let appWorlds: AppWorlds

        /// The main ECS world, provided as a convenience for embedded clients.
        public var world: World {
            appWorlds.main
        }

        /// Called when asynchronous startup fails.
        public var onError: (@MainActor (Error) -> Void)?

        /// Called after the renderer and Metal window are ready.
        public var onReady: ReadyHandler?

        private var displayLink: CADisplayLink?
        private weak var displayLinkScreen: UIScreen?
        private var updateTask: Task<Void, Never>?
        private var startupTask: Task<Void, Never>?
        private var configuredFrameRateRange: ClosedRange<Int>?
        private var isRenderWindowCreated = false
        private var isStopped = false
        private var pendingWorldAccesses: [@MainActor (World) -> Void] = []

        /// Creates a host for a 3D AdaEngine world.
        ///
        /// - Parameters:
        ///   - frame: Initial UIKit frame.
        ///   - assetBundle: Bundle used by the asset loader.
        ///   - configure: Called before plugins are built. Add custom plugins and
        ///     systems here.
        ///   - onReady: Called after the renderer and Metal window are ready. This
        ///     is the appropriate place to create GPU-backed meshes and entities.
        public init(
            frame: CGRect,
            assetBundle: Bundle? = nil,
            configure: (@MainActor (AppWorlds) -> Void)? = nil,
            onReady: ReadyHandler? = nil
        ) {
            let windowID = RID()
            let appWorlds = AppWorlds(main: World(name: "EmbeddedMainWorld"))
            self.appWorlds = appWorlds
            self.onReady = onReady

            super.init(windowId: windowID, frame: frame)

            appWorlds
                .addPlugin(MainSchedulerPlugin())
                .addPlugin(EmbeddedRenderingPlugins(assetBundle: assetBundle))
                .insertResource(PrimaryWindowId(windowId: windowID))
                .insertResource(ApplicationFramePacing.displaySynchronized())
                .insertResource(SimulationControl())

            configure?(appWorlds)
            start()
        }

        @available(*, unavailable)
        public required init(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        isolated deinit {
            displayLink?.invalidate()
            startupTask?.cancel()
            updateTask?.cancel()
        }

        /// Pauses world updates while retaining the renderer and ECS state.
        public func pause() {
            displayLink?.isPaused = true
        }

        /// Resumes world updates.
        public func resume() {
            guard !isStopped else {
                return
            }
            displayLink?.isPaused = false
        }

        /// Performs access to the main world without racing the host's frame update.
        ///
        /// Access runs immediately between frames. If a frame is currently updating,
        /// it is deferred until all systems in that frame have finished.
        public func performWorldAccess(_ access: @escaping @MainActor (World) -> Void) {
            guard !isStopped else {
                return
            }
            guard updateTask != nil else {
                access(world)
                return
            }
            pendingWorldAccesses.append(access)
        }

        /// Permanently stops this host and releases its render window.
        public func stop() {
            guard !isStopped else {
                return
            }
            isStopped = true
            displayLink?.invalidate()
            displayLink = nil
            displayLinkScreen = nil
            startupTask?.cancel()
            startupTask = nil
            updateTask?.cancel()
            updateTask = nil
            configuredFrameRateRange = nil
            pendingWorldAccesses.removeAll(keepingCapacity: false)

            guard isRenderWindowCreated else {
                return
            }
            do {
                try unsafe RenderEngine.shared.destroyWindow(windowID)
            } catch {
                onError?(error)
            }
            isRenderWindowCreated = false
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            resizeRenderWindowIfNeeded()
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            if isRenderWindowCreated {
                installDisplayLink()
            }
            displayLink?.isPaused = window == nil
        }

        private func start() {
            startupTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try await appWorlds.build()
                    guard !Task.isCancelled, !isStopped else {
                        return
                    }

                    let size = renderSize
                    try unsafe RenderEngine.shared.createWindow(windowID, for: self, size: size)
                    isRenderWindowCreated = true
                    onReady?(appWorlds)

                    installDisplayLink()
                } catch {
                    onError?(error)
                }
                startupTask = nil
            }
        }

        private func installDisplayLink() {
            let screen = window?.screen ?? UIScreen.main
            guard displayLink == nil || displayLinkScreen !== screen else {
                return
            }

            displayLink?.invalidate()
            configuredFrameRateRange = nil
            let displayLink =
                screen.displayLink(withTarget: self, selector: #selector(updateFrame))
                ?? CADisplayLink(target: self, selector: #selector(updateFrame))
            configureFrameRate(for: displayLink)
            displayLink.add(to: .main, forMode: .common)
            displayLink.isPaused = window == nil
            self.displayLink = displayLink
            self.displayLinkScreen = screen
        }

        @objc private func updateFrame() {
            if let displayLink {
                configureFrameRate(for: displayLink)
            }
            guard updateTask == nil, !isStopped else {
                return
            }
            updateTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                defer {
                    if isStopped {
                        pendingWorldAccesses.removeAll(keepingCapacity: false)
                    } else {
                        applyPendingWorldAccesses()
                    }
                    updateTask = nil
                }
                do {
                    try await appWorlds.update()
                } catch {
                    onError?(error)
                }
            }
        }

        private func applyPendingWorldAccesses() {
            let accesses = pendingWorldAccesses
            pendingWorldAccesses.removeAll(keepingCapacity: true)
            for access in accesses {
                access(world)
            }
        }

        private func configureFrameRate(for displayLink: CADisplayLink) {
            guard let framePacing = appWorlds.getResource(ApplicationFramePacing.self) else {
                return
            }
            let displayMaximumFramesPerSecond =
                window?.screen.maximumFramesPerSecond
                ?? UIScreen.main.maximumFramesPerSecond
            let range = framePacing.resolvedFrameRateRange(
                forDisplayMaximumFramesPerSecond: displayMaximumFramesPerSecond
            )
            guard configuredFrameRateRange != range else {
                return
            }
            configuredFrameRateRange = range
            displayLink.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(range.lowerBound),
                maximum: Float(range.upperBound),
                preferred: Float(range.upperBound)
            )
        }

        private func resizeRenderWindowIfNeeded() {
            guard isRenderWindowCreated, bounds.width > 0, bounds.height > 0 else {
                return
            }
            do {
                try unsafe RenderEngine.shared.resizeWindow(
                    windowID,
                    newSize: renderSize,
                    scaleFactor: Float(contentScaleFactor)
                )
            } catch {
                onError?(error)
            }
        }

        private var renderSize: SizeInt {
            SizeInt(
                width: max(1, Int(drawableSize.width)),
                height: max(1, Int(drawableSize.height))
            )
        }
    }

    private struct EmbeddedRenderingPlugins: Plugin {
        let assetBundle: Bundle?

        func setup(in app: AppWorlds) {
            app
                .addPlugin(TransformPlugin())
                .addPlugin(InputPlugin())
                .addPlugin(RenderWorldPlugin())
                .addPlugin(EventsPlugin())
                .addPlugin(CameraPlugin())
                .addPlugin(AssetsPlugin(filePath: #filePath, assetBundle: assetBundle))
                .addPlugin(VisibilityPlugin())
                .addPlugin(ScenePlugin())
                .addPlugin(ScriptableObjectPlugin())
                .addPlugin(Core3DPlugin())
                .addPlugin(UpscalePlugin())
        }
    }
#endif
