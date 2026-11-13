//
//  AppleEmbeddedWindowManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 7/11/22.
//

#if IOS || TVOS || VISIONOS
    import AdaECS
    @_spi(Internal) import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Math
    import MetalKit
    import UIKit

    final class AppleEmbeddedWindowManager: UIWindowManager {
        #if IOS
            var onNativeWindowPresented: (@MainActor (UIKit.UIView) -> Void)?
        #endif
        private let screenManager: any ScreenManager
        private(set) var isUIKitReady = false
        private var pendingWindowCreations: [AdaUI.UIWindow] = []
        private var pendingWindows: [(window: AdaUI.UIWindow, isFocused: Bool)] = []
        var pendingSceneWindows: [String: (window: AdaUI.UIWindow, isFocused: Bool)] = [:]
        var cancelledSceneRequestTokens: Set<String> = []
        var windowIDsBySceneSession: [String: AdaUI.UIWindow.ID] = [:]
        var dedicatedSceneSessionIDs: Set<String> = []

        init(screenManager: any ScreenManager) {
            self.screenManager = screenManager
        }

        func sceneDidConnect(_ windowScene: UIWindowScene, requestToken: String? = nil) {
            isUIKitReady = true

            let pendingCreations = pendingWindowCreations
            pendingWindowCreations.removeAll()
            for window in pendingCreations {
                createNativeWindow(for: window, scene: windowScene)
            }

            if destroySceneIfRequestWasCancelled(requestToken, windowScene: windowScene) {
                return
            }

            if let requestToken,
                let pendingWindow = pendingSceneWindows.removeValue(forKey: requestToken) {
                dedicatedSceneSessionIDs.insert(windowScene.session.persistentIdentifier)
                presentWindow(
                    pendingWindow.window,
                    isFocused: pendingWindow.isFocused,
                    scene: windowScene
                )
                return
            }

            if let windowID = windowIDsBySceneSession[windowScene.session.persistentIdentifier],
                let window = windows[windowID] {
                presentWindow(window, isFocused: windowScene.activationState == .foregroundActive, scene: windowScene)
                return
            }

            let pending = pendingWindows
            pendingWindows.removeAll()
            for entry in pending {
                if entry.window.configuration.scenePresentation == .new {
                    requestNewScene(for: entry.window, isFocused: entry.isFocused)
                } else {
                    presentWindow(entry.window, isFocused: entry.isFocused, scene: windowScene)
                }
            }
        }

        override func createWindow(for window: AdaUI.UIWindow) {
            // WindowPlugin runs before UIApplicationMain. UIKit's gesture environment
            // does not exist yet, so even constructing a UIView/UIWindow here is unsafe.
            guard isUIKitReady else {
                if !pendingWindowCreations.contains(where: { $0 === window }) {
                    pendingWindowCreations.append(window)
                }
                return
            }

            createNativeWindow(for: window, scene: activeWindowScene())
        }

        private func createNativeWindow(for window: AdaUI.UIWindow, scene connectedScene: UIWindowScene?) {
            let scene =
                window.configuration.scenePresentation == .new
                ? nil
                : connectedScene
            #if os(visionOS)
            let sceneBounds = scene?.coordinateSpace.bounds ?? CGRect(
                x: 0, y: 0, width: CGFloat(window.frame.size.width), height: CGFloat(window.frame.size.height)
            )
            #else
            let screen = scene?.screen ?? UIScreen.main
            let sceneBounds = scene?.coordinateSpace.bounds ?? screen.bounds
            #endif
            let frame = sceneBounds.toEngineRect

            // Register view in engine
            let gameViewController = _AdaEngineViewController(window: window.id, frame: sceneBounds)

            // Setup windowManager reference for input handling
            gameViewController.renderView.windowManager = self

            let systemWindow: _AdaUIWindow
            if let scene {
                systemWindow = _AdaUIWindow(
                    windowScene: scene,
                    frame: sceneBounds,
                    windowManager: self
                )
            } else {
                systemWindow = _AdaUIWindow(frame: sceneBounds, windowManager: self)
            }
            systemWindow.rootViewController = gameViewController
            systemWindow.backgroundColor = .black

            #if !os(tvOS)
                if Self.supportsPointerInteraction() {
                    let pointerInteraction = UIPointerInteraction(delegate: systemWindow)
                    systemWindow.addInteraction(pointerInteraction)
                    systemWindow.pointerInteraction = pointerInteraction
                }
            #endif

            window.systemWindow = systemWindow
            window.minSize = frame.size
            window.userInterfaceIdiom = Self.detectIdiom()

            unsafe try? RenderEngine.shared.createWindow(
                window.id,
                for: gameViewController.renderView,
                size: frame.size.toSizeInt()
            )

            super.createWindow(for: window)
        }

        // - TODO: (Vlad) I'm not really sure, that we should make window unfocused
        override func showWindow(_ window: AdaUI.UIWindow, isFocused: Bool) {
            guard isUIKitReady else {
                pendingWindows.removeAll { $0.window === window }
                pendingWindows.append((window: window, isFocused: isFocused))
                return
            }

            if window.configuration.scenePresentation == .new,
                (window.systemWindow as? UIKit.UIWindow)?.windowScene == nil {
                requestNewScene(for: window, isFocused: isFocused)
                return
            }

            presentWindow(window, isFocused: isFocused, scene: nil)
        }

        func presentWindow(_ window: AdaUI.UIWindow, isFocused: Bool, scene: UIWindowScene?) {
            guard let uiWindow = window.systemWindow as? UIKit.UIWindow else {
                fatalError("System window not exist.")
            }

            attachWindowToSceneIfNeeded(uiWindow, preferredScene: scene)
            if isFocused, let sceneDelegate = uiWindow.windowScene?.delegate as? AppleEmbeddedSceneDelegate {
                sceneDelegate.window = uiWindow
            }
            if let sessionIdentifier = uiWindow.windowScene?.session.persistentIdentifier {
                windowIDsBySceneSession[sessionIdentifier] = window.id
            }
            if isFocused {
                uiWindow.makeKeyAndVisible()
            } else {
                uiWindow.isHidden = false
            }

            if isFocused, let appDelegate = UIApplication.shared.delegate as? AppleEmbeddedAppDelegate {
                appDelegate.window = uiWindow
            }

            window.windowDidAppear()
            #if IOS
                onNativeWindowPresented?(uiWindow)
            #endif

            if isFocused {
                self.setActiveWindow(window)
            }
        }

        override func setWindowMode(_ window: AdaUI.UIWindow, mode: AdaUI.UIWindow.Mode) {
            window.isFullscreen = mode != .windowed
        }

        override func closeWindow(_ window: AdaUI.UIWindow) {
            if pendingWindowCreations.contains(where: { $0 === window }) {
                pendingWindowCreations.removeAll { $0 === window }
                pendingWindows.removeAll { $0.window === window }
                window.windowDidDisappear()
                return
            }

            guard let nsWindow = window.systemWindow as? UIKit.UIWindow else {
                fatalError("System window not exist.")
            }

            cancelPendingSceneRequests(for: window)
            let sceneSession = nsWindow.windowScene?.session
            if let sceneSession {
                windowIDsBySceneSession.removeValue(forKey: sceneSession.persistentIdentifier)
            }

            self.removeWindow(window, setActiveAnotherIfNeeded: true)

            nsWindow.isHidden = true
            nsWindow.windowScene = nil

            if let sceneSession,
                dedicatedSceneSessionIDs.remove(sceneSession.persistentIdentifier) != nil {
                UIApplication.shared.requestSceneSessionDestruction(sceneSession, options: nil)
            }
        }

        override func getScreen(for window: AdaUI.UIWindow) -> Screen? {
            #if os(visionOS)
            return nil
            #else
            guard let screen = (window.systemWindow as? UIKit.UIWindow)?.screen else {
                return nil
            }

            return Screen(systemScreen: screen, screenManager: screenManager)
            #endif
        }

        override func resizeWindow(_ window: AdaUI.UIWindow, size: Math.Size) {
            guard let uiWindow = window.systemWindow as? UIKit.UIWindow else {
                return
            }

            let currentOrigin = uiWindow.frame.origin
            let newFrame = CGRect(origin: currentOrigin, size: size.toCGSize)

            uiWindow.frame = newFrame
            uiWindow.rootViewController?.view.frame = CGRect(origin: .zero, size: size.toCGSize)
        }

        override func setMinimumSize(_ size: Size, for window: AdaUI.UIWindow) {
            guard let uiWindow = window.systemWindow as? UIKit.UIWindow else {
                return
            }

            let currentSize = uiWindow.frame.size.toEngineSize
            let clampedSize = Size(
                width: max(currentSize.width, size.width),
                height: max(currentSize.height, size.height)
            )

            if clampedSize != currentSize {
                resizeWindow(window, size: clampedSize)
            }
        }

        private(set) var currentShape: Input.CursorShape = .arrow
        private(set) var mouseMode: Input.MouseMode = .visible

        override func updateCursor() {
            #if !os(tvOS)
                guard let window = self.activeWindow?.systemWindow as? _AdaUIWindow else {
                    return
                }

                window.pointerInteraction?.invalidate()
            #endif
        }

        override func setCursorImage(
            for _: Input.CursorShape,
            texture _: Texture2D?,
            hotspot _: Vector2
        ) {
        }

        override func setCursorShape(_ shape: Input.CursorShape) {
            self.currentShape = shape

            self.updateCursor()
        }

        override func getMouseMode() -> Input.MouseMode {
            return self.mouseMode
        }

        override func setMouseMode(_ mode: Input.MouseMode) {
            self.mouseMode = mode

            self.updateCursor()
        }

        override func getCursorShape() -> Input.CursorShape {
            return self.currentShape
        }

        override func textInputFocusDidChange(_ isFocused: Bool) {
            guard
                let gameVC = (activeWindow?.systemWindow as? UIKit.UIWindow)?
                    .rootViewController as? _AdaEngineViewController
            else {
                return
            }
            gameVC.renderView.showsKeyboard = isFocused
            gameVC.renderView.reloadInputViews()
            if isFocused, !gameVC.renderView.isFirstResponder {
                gameVC.renderView.becomeFirstResponder()
            }
        }

        func findWindow(for nsWindow: UIKit.UIWindow) -> AdaUI.UIWindow? {
            return self.windows.first {
                ($0.systemWindow as? UIKit.UIWindow) === nsWindow
            }
        }

        private static func detectIdiom() -> UserInterfaceIdiom {
            _AdaEngineViewController.idiom(from: .current)
        }

        #if !os(tvOS)
            private static func supportsPointerInteraction() -> Bool {
                #if os(iOS)
                    detectIdiom() == .pad
                #else
                    true
                #endif
            }
        #endif

        private func attachWindowToSceneIfNeeded(_ window: UIKit.UIWindow, preferredScene: UIWindowScene? = nil) {
            let scene: UIWindowScene
            if let preferredScene {
                scene = preferredScene
            } else {
                guard window.windowScene == nil, let found = activeWindowScene() else {
                    return
                }
                scene = found
            }

            window.windowScene = scene
            window.frame = scene.coordinateSpace.bounds
            window.rootViewController?.view.frame = scene.coordinateSpace.bounds

            if let sceneDelegate = scene.delegate as? AppleEmbeddedSceneDelegate {
                sceneDelegate.window = window
            }
        }
    }

    final class _AdaUIWindow: UIKit.UIWindow, SystemWindow {
        public var title: String = ""

        public var size: Size {
            get {
                return self.frame.size.toEngineSize
            }
            set {
                self.frame.size = CGSize(
                    width: CGFloat(newValue.width),
                    height: CGFloat(newValue.height)
                )
            }
        }

        public var position: Point {
            get {
                return self.frame.origin.toEnginePoint
            }
            set {
                self.frame.origin = CGPoint(
                    x: CGFloat(newValue.x),
                    y: CGFloat(newValue.y)
                )
            }
        }

        #if !os(tvOS)
            weak var pointerInteraction: UIPointerInteraction?
        #endif
        private var windowManager: AppleEmbeddedWindowManager?

        init(frame: CGRect, windowManager: AppleEmbeddedWindowManager) {
            self.windowManager = windowManager
            super.init(frame: frame)
        }

        @available(iOS 13.0, tvOS 13.0, *)
        init(windowScene: UIWindowScene, frame: CGRect, windowManager: AppleEmbeddedWindowManager) {
            self.windowManager = windowManager
            super.init(windowScene: windowScene)
            self.frame = frame
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIKit.UIView? {
            if let view = super.hitTest(point, with: event) {
                return view
            }

            guard
                !isHidden,
                alpha > 0.01,
                isUserInteractionEnabled,
                bounds.contains(point)
            else {
                return nil
            }

            return rootViewController?.view
        }

        #if os(iOS) && DEBUG
            override func motionEnded(_ motion: UIEvent.EventSubtype, with event: UIEvent?) {
                super.motionEnded(motion, with: event)

                guard motion == .motionShake,
                    let window = windowManager?.findWindow(for: self)
                else {
                    return
                }

                for container in window.uiInspectableContainers() {
                    let mode: AdaUI.UIDebugOverlayMode = container.uiInspectionOverlayMode == .layoutBounds
                        ? .off
                        : .layoutBounds
                    container.uiSetDebugOverlay(mode)
                }
            }
        #endif

    }

    #if !os(tvOS)
        extension _AdaUIWindow: UIPointerInteractionDelegate {
            func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
                if windowManager?.getMouseMode() == .hidden {
                    return UIPointerStyle.hidden()
                }

                let cursorShape = windowManager?.getCursorShape() ?? .arrow

                if cursorShape != .iBeam, #available(iOS 15.0, visionOS 1.0, *) {
                    return UIPointerStyle.system()
                }
                return UIPointerStyle.hidden()
            }
        }
    #endif

    final class _AdaEngineViewController: UIViewController {
        var renderView: MetalView
        nonisolated(unsafe) private var keyboardNotificationObservers: [NSObjectProtocol] = []

        init(window: AdaUI.UIWindow.ID, frame: CGRect) {
            self.renderView = MetalView(windowId: window, frame: frame)
            super.init(nibName: nil, bundle: nil)
        }

        required init?(coder _: NSCoder) {
            fatalErrorMethodNotImplemented()
        }

        deinit {
            for observer in keyboardNotificationObservers {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        override func loadView() {
            self.view = self.renderView
        }

        override func viewDidLoad() {
            super.viewDidLoad()
            registerKeyboardNotifications()
            #if IOS && compiler(>=6.4)
                if #available(iOS 27.1, *) {
                    view.addInteraction(UIHingeInteraction { [weak self] _, update in
                        guard let self, let window = renderView.windowManager?.windows[renderView.windowID] else { return }
                        window.deviceHinge = update.hinge.map { hinge in
                            let status: DeviceHinge.Status
                            switch hinge.status {
                            case .closed: status = .closed
                            case .partiallyOpen: status = .partiallyOpen
                            case .fullyOpen: status = .fullyOpen
                            default: status = .unknown
                            }
                            return DeviceHinge(status: status, angle: Float(hinge.angle))
                        }
                        propagateReservedRegions()
                        window.setNeedsLayout()
                    })
                }
            #endif
            registerForTraitChanges(
                [
                    UITraitUserInterfaceIdiom.self,
                    UITraitUserInterfaceStyle.self,
                    UITraitHorizontalSizeClass.self,
                    UITraitVerticalSizeClass.self,
                ]
            ) { [weak self] (_: Self, _: UITraitCollection) in
                self?.propagateTraits()
            }
        }

        private func registerKeyboardNotifications() {
            #if IOS
                let notifications: [(Notification.Name, KeyboardEvent.Phase)] = [
                    (UIResponder.keyboardWillShowNotification, .willShow),
                    (UIResponder.keyboardDidShowNotification, .didShow),
                    (UIResponder.keyboardWillHideNotification, .willHide),
                    (UIResponder.keyboardDidHideNotification, .didHide),
                    (UIResponder.keyboardWillChangeFrameNotification, .willChangeFrame),
                    (UIResponder.keyboardDidChangeFrameNotification, .didChangeFrame),
                ]

                keyboardNotificationObservers = notifications.map { name, phase in
                    NotificationCenter.default.addObserver(
                        forName: name,
                        object: nil,
                        queue: .main
                    ) { [weak self] notification in
                        let userInfo = notification.userInfo ?? [:]
                        let beginScreenFrame = userInfo[UIResponder.keyboardFrameBeginUserInfoKey] as? CGRect ?? .zero
                        let endScreenFrame = userInfo[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect ?? .zero
                        let animationDuration = userInfo[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0
                        let animationCurve = userInfo[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int ?? 0

                        MainActor.assumeIsolated {
                            self?
                                .receiveKeyboardNotification(
                                    phase: phase,
                                    beginScreenFrame: beginScreenFrame,
                                    endScreenFrame: endScreenFrame,
                                    animationDuration: animationDuration,
                                    animationCurve: animationCurve
                                )
                        }
                    }
                }
            #endif
        }

        @MainActor
        private func receiveKeyboardNotification(
            phase: KeyboardEvent.Phase,
            beginScreenFrame: CGRect,
            endScreenFrame: CGRect,
            animationDuration: Double,
            animationCurve: Int
        ) {
            #if IOS
                guard let input = renderView.input else {
                    return
                }

                let beginFrame = convertKeyboardFrameToView(beginScreenFrame)
                let endFrame = convertKeyboardFrameToView(endScreenFrame)
                let occlusion = KeyboardOcclusion(
                    viewBounds: view.bounds.toEngineRect,
                    keyboardFrame: endFrame.toEngineRect,
                    isHidden: phase == .willHide || phase == .didHide
                )

                input.wrappedValue.receiveEvent(
                    KeyboardEvent(
                        window: renderView.windowID,
                        phase: phase,
                        beginFrame: beginFrame.toEngineRect,
                        endFrame: endFrame.toEngineRect,
                        occludedFrame: occlusion.frame,
                        occludedHeight: occlusion.height,
                        animationDuration: AdaUtils.TimeInterval(animationDuration),
                        animationCurve: animationCurve,
                        time: AdaUtils.TimeInterval(CACurrentMediaTime())
                    )
                )

                guard let adaWindow = renderView.windowManager?.windows[renderView.windowID] else {
                    return
                }

                adaWindow.keyboardOccludedHeight = occlusion.height
                for subview in adaWindow.subviews {
                    subview.keyboardOccludedHeight = occlusion.height
                }
            #endif
        }

        private func convertKeyboardFrameToView(_ screenFrame: CGRect) -> CGRect {
            #if IOS
                let windowFrame = view.window?.convert(screenFrame, from: nil) ?? screenFrame
                return view.convert(windowFrame, from: nil)
            #else
                return .zero
            #endif
        }

        override func viewSafeAreaInsetsDidChange() {
            super.viewSafeAreaInsetsDidChange()
            propagateSafeAreaInsets()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()

            self.propagateTraits()
            self.propagateSize()
            self.propagateSafeAreaInsets()
            #if IOS
                (renderView.windowManager as? AppleEmbeddedWindowManager)?.onNativeWindowPresented?(view)
            #endif
            #if IOS && compiler(>=6.4)
                propagateReservedRegions()
            #endif
        }

        private func propagateSize() {
            guard
                let wm = renderView.windowManager,
                let adaWindow = wm.windows[renderView.windowID]
            else {
                return
            }

            let newSize = view.bounds.size.toEngineSize
            guard adaWindow.frame.size != newSize else {
                return
            }

            adaWindow.frame = Rect(origin: .zero, size: newSize)

            let sizeInt = SizeInt(width: Int(newSize.width), height: Int(newSize.height))
            unsafe try? RenderEngine.shared.resizeWindow(renderView.windowID, newSize: sizeInt)
        }

        private func propagateTraits() {
            guard let adaWindow = renderView.windowManager?.windows[renderView.windowID] else {
                return
            }
            adaWindow.userInterfaceIdiom = Self.idiom(from: traitCollection)
            adaWindow.colorScheme = Self.colorScheme(from: traitCollection)
            adaWindow.horizontalSizeClass = Self.sizeClass(from: traitCollection.horizontalSizeClass)
            adaWindow.verticalSizeClass = Self.sizeClass(from: traitCollection.verticalSizeClass)
            adaWindow.setNeedsLayout()
        }

        private static func sizeClass(from value: UIUserInterfaceSizeClass) -> UserInterfaceSizeClass? {
            switch value {
            case .compact: return .compact
            case .regular: return .regular
            default: return nil
            }
        }

        #if IOS && compiler(>=6.4)
            private func propagateReservedRegions() {
                guard #available(iOS 27.1, *), let window = renderView.windowManager?.windows[renderView.windowID] else { return }
                let kinds: [(UIKit.UIView.ReservedRegion.Kind, ViewReservedRegion.Kind)] = [(.division, .division), (.occlusion, .occlusion)]
                window.reservedRegions = kinds.flatMap { nativeKind, kind in
                    view.reservedRegions(kind: nativeKind, options: .includeInactive).map { region in
                        ViewReservedRegion(
                            id: String(describing: region.id), kind: kind, frame: region.frame.toEngineRect,
                            margins: EdgeInsets(top: Float(region.margins.top), leading: Float(region.margins.left),
                                bottom: Float(region.margins.bottom), trailing: Float(region.margins.right)),
                            isActive: region.isActive
                        )
                    }
                }
                propagateSafeAreaInsets()
            }
        #endif

        static func idiom(from traits: UITraitCollection) -> UserInterfaceIdiom {
            #if VISIONOS
                return .xr
            #elseif TVOS
                return .tv
            #else
                switch traits.userInterfaceIdiom {
                case .phone: return .phone
                case .pad: return .pad
                case .mac: return .desktop
                default: return .phone
                }
            #endif
        }

        private static func colorScheme(from traits: UITraitCollection) -> ColorScheme {
            traits.userInterfaceStyle == .dark ? .dark : .light
        }

        private func propagateSafeAreaInsets() {
            let uiInsets = view.safeAreaInsets
            let engineInsets = EdgeInsets(
                top: Float(uiInsets.top),
                leading: Float(uiInsets.left),
                bottom: Float(uiInsets.bottom),
                trailing: Float(uiInsets.right)
            )
            // Look up by window ID rather than activeWindow — activeWindow may be
            // nil during the initial layout pass that precedes setActiveWindow.
            guard let adaWindow = renderView.windowManager?.windows[renderView.windowID] else {
                return
            }
            // Store on the window so UIContainerView can read it when attached later
            // (WindowGroupUpdateSystem adds the container view on the first ECS tick,
            // which is after the first viewSafeAreaInsetsDidChange call).
            adaWindow.safeAreaInsets = engineInsets
            #if IOS
                if let statusBarFrame = view.window?.windowScene?.statusBarManager?.statusBarFrame {
                    let frame = view.convert(statusBarFrame, from: nil)
                    let statusInset = frame.minY < view.bounds.midY ? max(0, frame.maxY - uiInsets.top) : 0
                    let sideInset = max(uiInsets.left, uiInsets.right)
                    // The vertical status area includes the camera/activity capsule; the
                    // legacy statusBarFrame may only describe its thin clock baseline.
                    let sideOcclusionBottom = adaWindow.reservedRegions
                        .filter { region in
                            region.isActive && region.kind == .occlusion
                                && region.frame.minY <= Float(uiInsets.top) + 1
                                && (region.frame.minX <= 1 || region.frame.maxX >= Float(view.bounds.width) - 1)
                        }
                        .map { CGFloat($0.frame.maxY + $0.margins.bottom) }
                        .max()
                    let hasSideOcclusion = adaWindow.reservedRegions.contains { region in
                        region.isActive && region.kind == .occlusion
                            && (region.frame.minX < Float(uiInsets.left) || region.frame.maxX > Float(view.bounds.width - uiInsets.right))
                    }
                    // Closed Duo displays can omit reserved regions. statusBarFrame
                    // covers the clock, while the network/activity control extends
                    // below it. Reserve the complete two-side-width system strip.
                    // A bottom-facing/hidden status area must not reserve top space.
                    let fallbackStatusInset = !hasSideOcclusion && statusInset > 0 ? sideInset * 2 : 0
                    let verticalStatusInset = sideInset >= 60 ? sideOcclusionBottom ?? fallbackStatusInset : 0
                    adaWindow.navigationBarControlsTopInset = Float(max(statusInset, verticalStatusInset))
                } else {
                    adaWindow.navigationBarControlsTopInset = 0
                }
            #endif
            for subview in adaWindow.subviews {
                if let provider = subview as? SafeAreaProvider {
                    provider.safeAreaInsets = engineInsets
                    provider.setNeedsLayout()
                }
            }
        }
    }
#endif
