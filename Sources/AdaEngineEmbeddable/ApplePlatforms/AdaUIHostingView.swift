#if canImport(UIKit)
    @_spi(Internal) import AdaApp
    @_spi(Internal) import AdaAssets
    import AdaCorePipelines
    import AdaECS
    import AdaEngine
    import AdaInput
    @_spi(Internal) import AdaPlatform
    @_spi(Internal) import AdaRender
    import AdaText
    import AdaTransform
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import Math
    import MetalKit
    import UIKit

    /// Native surface for an AdaUI panel. It creates no UIApplication, platform window,
    /// or process-wide window manager. Each host acquires only its own Metal drawable.
    @MainActor
    public final class AdaUIHostingView<Content: AdaUI.View>: MetalView {
        public var onError: (@MainActor (Error) -> Void)?
        public let appWorlds: AppWorlds
        public let engineWindow: AdaUI.UIWindow

        private let panelManager: EmbeddedPanelWindowManager
        private var content: Content
        private var container: UIContainerView<EmbeddedPanelRoot<Content>>?
        private var displayLink: CADisplayLink?
        private var displayTarget: EmbeddedPanelDisplayTarget?
        private var startupTask: Task<Void, Never>?
        private var updateTask: Task<Void, Never>?
        private var pendingContent: Content?
        private var pendingColorScheme: AdaUI.ColorScheme = .light
        private var needsResize = true
        private var didCreateRenderWindow = false
        private var isStopped = false

        public init(content: Content, assetBundle: Bundle? = nil) {
            self.content = content
            let manager = EmbeddedPanelWindowManager()
            panelManager = manager
            let frame = Rect(x: 0, y: 0, width: 360, height: 460)
            engineWindow = AdaUI.UIWindow(frame: frame, configuration: .init(frame: frame, showsImmediately: false), windowManager: manager)
            appWorlds = AppWorlds(main: World(name: "EmbeddedAdaUIPanel"))
            super.init(windowId: engineWindow.id, frame: CGRect(x: 0, y: 0, width: 360, height: 460))
            bindWindowManager(manager)
            setEmbeddedTransparency(true)
            manager.host = self
            isOpaque = false
            layer.isOpaque = false
            backgroundColor = .clear
            colorPixelFormat = .bgra8Unorm
            appWorlds
                .insertResource(WindowManagerResource(windowManager: manager))
                .insertResource(PrimaryWindowId(windowId: engineWindow.id))
                .insertResource(RenderWindowScope(windowIDs: [engineWindow.id]))
                .addPlugin(MainSchedulerPlugin())
                .addPlugin(EmbeddedPanelPlugins(assetBundle: assetBundle))
            startupTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                do {
                    try await appWorlds.build()
                    guard !isStopped, !Task.isCancelled else {
                        return
                    }
                    panelManager.inputRef = appWorlds.main.getRefResource(Input.self)
                    let root = UIContainerView(rootView: makeRoot(content))
                    root.backgroundColor = .clear
                    root.autoresizingRules = [.flexibleWidth, .flexibleHeight]
                    container = root
                    engineWindow.addSubview(root)
                    engineWindow.showWindow(makeFocused: true)
                    var camera = Camera(window: .windowId(engineWindow.id))
                    camera.backgroundColor = .clear
                    let entity = appWorlds.main.spawn("Embedded Panel Camera", bundle: Camera2D(camera: camera))
                    engineWindow.runtimeCameraEntity = entity
                    try unsafe RenderEngine.shared.createWindow(engineWindow.id, for: self, size: renderSize)
                    didCreateRenderWindow = true
                    applyPendingChanges()
                    installDisplayLink()
                } catch { report(error) }
                startupTask = nil
            }
        }

        @available(*, unavailable)
        public required init(coder _: NSCoder) { fatalError("Use init(content:assetBundle:)") }

        isolated deinit {
            displayLink?.invalidate()
            startupTask?.cancel()
            updateTask?.cancel()
        }

        public func updateContent(_ content: Content, colorScheme: AdaUI.ColorScheme) {
            pendingContent = content
            pendingColorScheme = colorScheme
            guard updateTask == nil, didCreateRenderWindow else {
                return
            }
            applyPendingChanges()
        }

        override public func layoutSubviews() {
            super.layoutSubviews()
            needsResize = true
            if updateTask == nil, didCreateRenderWindow { applyPendingChanges() }
        }

        override public func didMoveToWindow() {
            super.didMoveToWindow()
            engineWindow.systemWindow = EmbeddedPanelSystemWindow(view: self)
            engineWindow.nativeHostingView = self
            needsResize = true
            displayLink?.isPaused = window == nil
        }

        public func stop() {
            guard !isStopped else {
                return
            }
            isStopped = true
            displayLink?.invalidate()
            displayLink = nil
            displayTarget = nil
            startupTask?.cancel()
            updateTask?.cancel()
            let update = updateTask
            let startup = startupTask
            let worlds = appWorlds
            let manager = panelManager
            let panel = engineWindow
            let created = didCreateRenderWindow
            Task { @MainActor in
                await startup?.value
                await update?.value
                if created { manager.removeWindow(panel, setActiveAnotherIfNeeded: false) }
                await AssetsManager.destroyScope(worlds.executionID)
            }
        }

        private func makeRoot(_ content: Content) -> EmbeddedPanelRoot<Content> {
            EmbeddedPanelRoot(content: content, world: appWorlds.main, manager: panelManager)
        }

        private func applyPendingChanges() {
            if let pendingContent {
                content = pendingContent
                self.pendingContent = nil
                container?.updateRootView(makeRoot(content))
            }
            container?.colorScheme = pendingColorScheme
            panelManager.scale = Float(contentScaleFactor)
            panelManager.size = bounds.size.toEngineSize
            container?.safeAreaInsets = AdaUI.EdgeInsets(
                top: Float(safeAreaInsets.top),
                leading: Float(safeAreaInsets.left),
                bottom: Float(safeAreaInsets.bottom),
                trailing: Float(safeAreaInsets.right)
            )
            guard needsResize, bounds.width > 0, bounds.height > 0 else {
                return
            }
            needsResize = false
            let frame = Rect(x: 0, y: 0, width: Float(bounds.width), height: Float(bounds.height))
            engineWindow.frame = frame
            container?.frame = frame
            do {
                try unsafe RenderEngine.shared.resizeWindow(engineWindow.id, newSize: renderSize)
            } catch { report(error) }
            container?.setNeedsLayout()
        }

        private func installDisplayLink() {
            let target = EmbeddedPanelDisplayTarget { [weak self] link in self?.updateFrame(link) }
            let link = CADisplayLink(target: target, selector: #selector(EmbeddedPanelDisplayTarget.update(_:)))
            link.preferredFramesPerSecond = 60
            link.add(to: .main, forMode: .common)
            link.isPaused = window == nil
            displayTarget = target
            displayLink = link
        }

        private func updateFrame(_ link: CADisplayLink) {
            guard !isStopped, updateTask == nil else {
                return
            }
            applyPendingChanges()
            let delta = Float(min(max(link.targetTimestamp - link.timestamp, 0), 0.05))
            updateTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                defer { updateTask = nil }
                appWorlds.main.insertResource(DeltaTime(deltaTime: delta))
                do {
                    try await appWorlds.update()
                } catch { report(error) }
            }
        }

        private var renderSize: SizeInt {
            // RenderWindow stores logical points; its scale factor supplies physical pixels.
            SizeInt(width: max(1, Int(bounds.width)), height: max(1, Int(bounds.height)))
        }

        private func report(_ error: Error) {
            onError?(error)
            print("[AdaUIHost] \(error)")
        }
    }

    private struct EmbeddedPanelRoot<Content: AdaUI.View>: AdaUI.View {
        let content: Content
        let world: World
        let manager: UIWindowManager
        var body: some AdaUI.View {
            content.environment(\.world, world).environment(\.windowManager, manager)
        }
    }

    private struct EmbeddedPanelPlugins: Plugin {
        let assetBundle: Bundle?
        func setup(in app: AppWorlds) {
            app.addPlugin(TransformPlugin())
                .addPlugin(InputPlugin())
                .addPlugin(RenderWorldPlugin())
                .addPlugin(EventsPlugin())
                .addPlugin(CameraPlugin())
                .addPlugin(AssetsPlugin(filePath: #filePath, assetBundle: assetBundle))
                .addPlugin(Core2DPlugin())
                .addPlugin(TextPlugin())
                .addPlugin(UIPlugin())
                .addPlugin(UpscalePlugin())
        }
    }

    @MainActor
    private final class EmbeddedPanelDisplayTarget: NSObject {
        let tick: (CADisplayLink) -> Void
        init(tick: @escaping (CADisplayLink) -> Void) { self.tick = tick }
        @objc func update(_ link: CADisplayLink) { tick(link) }
    }

    @MainActor
    private protocol EmbeddedPanelFocusHost: AnyObject {
        func becomeFirstResponder() -> Bool
        func resignFirstResponder() -> Bool
        func stop()
    }

    extension AdaUIHostingView: EmbeddedPanelFocusHost {}

    @MainActor
    private final class EmbeddedPanelWindowManager: UIWindowManager, ScreenManager {
        weak var host: (any EmbeddedPanelFocusHost)?
        var size: Size = .zero
        var scale: Float = 1
        private let screenIdentity = EmbeddedPanelScreen()
        private lazy var panelScreen = Screen(systemScreen: screenIdentity, screenManager: self)
        override func showWindow(_ window: AdaUI.UIWindow, isFocused: Bool) { if isFocused { setActiveWindow(window) } }
        override func closeWindow(_: AdaUI.UIWindow) { host?.stop() }
        override func resizeWindow(_: AdaUI.UIWindow, size _: Size) {}
        override func setMinimumSize(_: Size, for _: AdaUI.UIWindow) {}
        override func setWindowMode(_: AdaUI.UIWindow, mode _: AdaUI.UIWindow.Mode) {}
        override func getScreen(for _: AdaUI.UIWindow) -> Screen? { panelScreen }
        override func setCursorShape(_: Input.CursorShape) {}
        override func getCursorShape() -> Input.CursorShape { .arrow }
        override func setMouseMode(_: Input.MouseMode) {}
        override func getMouseMode() -> Input.MouseMode { .visible }
        override func updateCursor() {}
        override func textInputFocusDidChange(_ isFocused: Bool) {
            if isFocused { _ = host?.becomeFirstResponder() } else { _ = host?.resignFirstResponder() }
        }
        nonisolated func getMainScreen() -> Screen? { MainActor.assumeIsolated { panelScreen } }
        nonisolated func getScreens() -> [Screen] { MainActor.assumeIsolated { [panelScreen] } }
        nonisolated func getSize(for _: Screen) -> Size { MainActor.assumeIsolated { size } }
        nonisolated func getScreenScale(for _: Screen) -> Float { MainActor.assumeIsolated { scale } }
        nonisolated func getBrightness(for _: Screen) -> Float { 1 }
        nonisolated func makeScreen(from systemScreen: SystemScreen) -> Screen {
            Screen(systemScreen: systemScreen, screenManager: self)
        }
    }

    @MainActor
    private final class EmbeddedPanelSystemWindow: SystemWindow {
        weak var view: UIKit.UIView?
        var title = ""
        init(view: UIKit.UIView) { self.view = view }
        var size: Size {
            get { view?.bounds.size.toEngineSize ?? .zero }
            set { view?.frame.size = CGSize(width: CGFloat(newValue.width), height: CGFloat(newValue.height)) }
        }
        var position: Point {
            get { .zero }
            set { _ = newValue }
        }
    }

    private final class EmbeddedPanelScreen: SystemScreen {}
#endif
