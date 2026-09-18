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
        private let screenManager: any ScreenManager
        private var isUIKitReady = false
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
                presentWindow(entry.window, isFocused: entry.isFocused, scene: windowScene)
            }
        }

        override func createWindow(for window: AdaUI.UIWindow) {
            let scene =
                window.configuration.scenePresentation == .new
                ? nil
                : activeWindowScene()
            let screen = scene?.screen ?? UIScreen.main
            let sceneBounds = scene?.coordinateSpace.bounds ?? screen.bounds
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

            if Self.supportsPointerInteraction() {
                let pointerInteraction = UIPointerInteraction(delegate: systemWindow)
                systemWindow.addInteraction(pointerInteraction)
                systemWindow.pointerInteraction = pointerInteraction
            }

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
            if window.configuration.scenePresentation == .new,
                (window.systemWindow as? UIKit.UIWindow)?.windowScene == nil {
                requestNewScene(for: window, isFocused: isFocused)
                return
            }

            guard !isUIKitReady else {
                presentWindow(window, isFocused: isFocused, scene: nil)
                return
            }
            pendingWindows.append((window: window, isFocused: isFocused))
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

            if isFocused {
                self.setActiveWindow(window)
            }
        }

        override func setWindowMode(_ window: AdaUI.UIWindow, mode: AdaUI.UIWindow.Mode) {
            window.isFullscreen = mode != .windowed
        }

        override func closeWindow(_ window: AdaUI.UIWindow) {
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
            guard let screen = (window.systemWindow as? UIKit.UIWindow)?.screen else {
                return nil
            }

            return Screen(systemScreen: screen, screenManager: screenManager)
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
            guard let window = self.activeWindow?.systemWindow as? _AdaUIWindow else {
                return
            }

            // Causes the interaction to update the pointer in response to an event.
            window.pointerInteraction?.invalidate()
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

        private static func supportsPointerInteraction() -> Bool {
            #if os(iOS)
                detectIdiom() == .pad
            #else
                true
            #endif
        }

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

    final class _AdaUIWindow: UIKit.UIWindow, SystemWindow, UIPointerInteractionDelegate {
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

        weak var pointerInteraction: UIPointerInteraction?
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

        // MARK: - UIPointerInteractionDelegate

        func pointerInteraction(_: UIPointerInteraction, styleFor _: UIPointerRegion) -> UIPointerStyle? {
            if windowManager?.getMouseMode() == .hidden {
                return UIPointerStyle.hidden()
            }

            var style: UIPointerStyle

            let cursorShape = windowManager?.getCursorShape() ?? .arrow

            switch cursorShape {
            case .iBeam:
                style = UIPointerStyle.hidden()
            default:
                if #available(iOS 15.0, visionOS 1.0, *) {
                    style = UIPointerStyle.system()
                } else {
                    // Fallback on earlier versions
                    style = UIPointerStyle.hidden()
                }
            }

            return style
        }
    }

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
                let occludedFrame = view.bounds.intersection(endFrame)
                let normalizedOccludedFrame = occludedFrame.isNull ? .zero : occludedFrame
                let occludedHeight = max(0, view.bounds.maxY - normalizedOccludedFrame.minY)

                input.wrappedValue.receiveEvent(
                    KeyboardEvent(
                        window: renderView.windowID,
                        phase: phase,
                        beginFrame: beginFrame.toEngineRect,
                        endFrame: endFrame.toEngineRect,
                        occludedFrame: normalizedOccludedFrame.toEngineRect,
                        occludedHeight: Float(occludedHeight),
                        animationDuration: AdaUtils.TimeInterval(animationDuration),
                        animationCurve: animationCurve,
                        time: AdaUtils.TimeInterval(CACurrentMediaTime())
                    )
                )

                guard let adaWindow = renderView.windowManager?.windows[renderView.windowID] else {
                    return
                }

                adaWindow.keyboardOccludedHeight = Float(occludedHeight)
                for subview in adaWindow.subviews {
                    subview.keyboardOccludedHeight = Float(occludedHeight)
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
            adaWindow.setNeedsLayout()
        }

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
            for subview in adaWindow.subviews {
                if let provider = subview as? SafeAreaProvider {
                    provider.safeAreaInsets = engineInsets
                    provider.setNeedsLayout()
                }
            }
        }
    }
#endif
