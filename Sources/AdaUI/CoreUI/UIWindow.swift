//
//  Window.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/29/22.
//

import AdaApp
import AdaECS
import AdaInput
import AdaUtils
import Foundation
import Math

/// The base class describes the window in the system.
/// Each window instance can be presented on the screen.
/// - Tag: AdaEngine.Window
@MainActor
open class UIWindow: UIView {
    public typealias ID = RID

    // TODO: (Vlad) Maybe, we should use unique ID without RID
    /// Identifier using to register window in the render engine.
    /// We use this id to start drawing.
    nonisolated public let id: ID = RID()

    public var configuration: Configuration

    public var title: String {
        get { self.systemWindow?.title ?? "" }
        set { self.systemWindow?.title = newValue }
    }

    public var windowManager: UIWindowManager {
        UIWindowManager.shared
    }

    @_spi(Internal) public var systemWindow: SystemWindow?
    @_spi(Internal) public var runtimeCameraEntity: Entity?
    internal let eventManager = EventManager()
    private var capturedMouseResponders: [MouseButton: WeakBox<UIView>] = [:]
    private var capturedTouchResponders: [RID: WeakBox<UIView>] = [:]

    /// Flag indicates that window can draw itself content in method ``UIView/draw(in:with:)``.
    open var canDraw: Bool = true

    private var dirtyRect: Rect?

    private var _minSize: Size = .zero
    public var minSize: Size {
        get {
            return _minSize
        }
        set {
            self.windowManager.setMinimumSize(newValue, for: self)
            self._minSize = newValue
        }
    }

    public var isFullscreen: Bool = false

    public var screen: Screen? {
        return windowManager.getScreen(for: self)
    }

    /// Flag indicates that window is active.
    public internal(set) var isActive: Bool = false

    /// Called after the native window or scene has been removed.
    public var onDidDisappear: (@MainActor () -> Void)?

    override public convenience init() {
        self.init(frame: .zero)
    }

    public convenience init(configuration: Configuration) {
        self.init(frame: configuration.frame, configuration: configuration)
    }

    public required init(frame: Rect) {
        self.configuration = Configuration(frame: frame)
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.windowManager.createWindow(for: self)
    }

    public init(frame: Rect, configuration: Configuration) {
        self.configuration = configuration
        super.init(frame: frame)
        self.backgroundColor = .clear
        self.windowManager.createWindow(for: self)
    }

    open func showWindow(makeFocused flag: Bool) {
        self.windowManager.showWindow(self, isFocused: flag)
    }

    open func close() {
        self.windowManager.closeWindow(self)
    }

    // MARK: - Public Methods

    open func setWindowMode(_ mode: UIWindow.Mode) {
        self.windowManager.setWindowMode(self, mode: mode)
    }

    // MARK: - Lifecycle

    /// Called one when window ready to use.
    open func windowDidReady() {
    }

    /// Called each time when window did appear on screen.
    open func windowDidAppear() {
    }

    /// Called once when window did disapper from screen.
    open func windowDidDisappear() {
        onDidDisappear?()
    }

    open func windowDidBecameActive() {
    }

    open func windowDidResignActive() {
    }

    /// Called when user did press `Close` button
    open func windowShouldClose() -> Bool {
        return true
    }

    func markDirty(_ rect: Rect) {
        if let dirtyRect {
            self.dirtyRect = dirtyRect.union(rect)
        } else {
            self.dirtyRect = rect
        }
    }

    func consumeDirtyRect() -> Rect? {
        defer {
            dirtyRect = nil
        }
        return dirtyRect
    }

    func sendEvent(_ event: any InputEvent) {
        guard self.canRespondToAction(event) else {
            return
        }

        if let mouse = event as? MouseEvent, routeCapturedMouseEvent(mouse) {
            return
        }
        if let touch = event as? TouchEvent, routeCapturedTouchEvent(touch) {
            return
        }
        let responder = self.findFirstResponder(for: event) ?? self.defaultResponder(for: event) ?? self
        if let mouse = event as? MouseEvent, mouse.phase == .began,
            mouse.button != .none, mouse.button != .scrollWheel {
            capturedMouseResponders[mouse.button] = WeakBox(responder)
        } else if let touch = event as? TouchEvent, touch.phase == .began {
            capturedTouchResponders[touch.contactID] = WeakBox(responder)
        }
        responder.onEvent(event)
    }

    /// Keep a drag with the view that received its press, even across sibling views or window bounds.
    private func routeCapturedMouseEvent(_ event: MouseEvent) -> Bool {
        if event.phase == .changed, event.button == .none {
            let captured = capturedMouseResponders
            capturedMouseResponders.removeAll(keepingCapacity: true)
            for (button, reference) in captured {
                guard let responder = reference.value, ownsResponder(responder) else {
                    continue
                }
                responder.onEvent(
                    MouseEvent(
                        window: id,
                        button: button,
                        mousePosition: event.mousePosition,
                        phase: .ended,
                        modifierKeys: event.modifierKeys,
                        time: event.time
                    )
                )
            }
            return false
        }
        guard
            event.phase != .began, event.button != .scrollWheel,
            let reference = capturedMouseResponders[event.button]
        else {
            return false
        }
        guard let responder = reference.value, ownsResponder(responder), responder.canRespondToAction(event) else {
            capturedMouseResponders.removeValue(forKey: event.button)
            return false
        }
        if event.phase == .ended || event.phase == .cancelled {
            capturedMouseResponders.removeValue(forKey: event.button)
        }
        responder.onEvent(event)
        return true
    }

    private func routeCapturedTouchEvent(_ event: TouchEvent) -> Bool {
        guard event.phase != .began, let responder = capturedTouchResponders[event.contactID]?.value else {
            return false
        }
        guard ownsResponder(responder), responder.canRespondToAction(event) else {
            capturedTouchResponders.removeValue(forKey: event.contactID)
            return false
        }
        if event.phase == .ended || event.phase == .cancelled {
            capturedTouchResponders.removeValue(forKey: event.contactID)
        }
        responder.onEvent(event)
        return true
    }

    private func ownsResponder(_ responder: UIView) -> Bool {
        responder === self || responder.window === self
    }

    private func defaultResponder(for event: any InputEvent) -> UIView? {
        switch event {
        case is KeyEvent,
            is TextInputEvent,
            is KeyboardEvent:
            if let focusedResponder = self.findFocusedInputResponderInSubviews(for: event) {
                return focusedResponder
            }

            // Keyboard/text events have no hit-test point, route to topmost
            // view container so it can forward input to the focused node.
            for subview in self.zSortedChildren.reversed() where subview.canRespondToAction(event) {
                return subview
            }
            return nil
        default:
            return nil
        }
    }

    private func findFocusedInputResponderInSubviews(for event: any InputEvent) -> UIView? {
        for subview in self.zSortedChildren.reversed() {
            if let focusedResponder = subview.findFocusedInputResponder(for: event) {
                return focusedResponder
            }
        }

        return nil
    }

    // MARK: - Overriding

    override open func frameDidChange() {
        self.windowManager.resizeWindow(self, size: self.frame.size)
        super.frameDidChange()
    }

    override public func addSubview(_ view: UIView) {
        guard !(view is UIWindow) else {
            assertionFailure("You cannot add window as subview to another window")
            return
        }

        if let anotherWindow = view.window {
            if anotherWindow === self {
                assertionFailure("View already added on this window.")
            } else {
                assertionFailure("You cannot add view as subview, because view holded by another window.")
            }
            return
        }

        super.addSubview(view)
    }

    override public func removeSubview(_ view: UIView) {
        if let window = view.window, window !== self {
            assertionFailure("You cant remove view from another window instance.")
            return
        }

        super.removeSubview(view)
    }
}

extension UIView {
    func findFocusedInputResponder(for event: any InputEvent) -> UIView? {
        for subview in self.zSortedChildren.reversed() {
            if let focusedResponder = subview.findFocusedInputResponder(for: event) {
                return focusedResponder
            }
        }

        guard
            self.canRespondToAction(event),
            let focusedContainer = self as? any FocusedInputContainer,
            focusedContainer.hasFocusedInputNode
        else {
            return nil
        }

        return self
    }
}

extension UIWindow {
    public struct Configuration: Sendable {
        public var title: String?
        public var frame: Rect
        public var minimumSize: Size
        public var mode: Mode
        public var chrome: Chrome
        public var titleBar: TitleBar
        public var background: Background
        public var backgroundEffect: BackgroundEffect
        public var level: Level
        public var collectionBehavior: CollectionBehavior
        public var screenPreference: WindowScreenPreference?
        public var showsImmediately: Bool
        public var makeKey: Bool
        public var hasShadow: Bool
        public var isResizable: Bool
        public var allowsMousePassthrough: Bool
        public var scenePresentation: ScenePresentation

        public init(
            title: String? = nil,
            frame: Rect = .zero,
            minimumSize: Size = UIWindow.defaultMinimumSize,
            mode: Mode = .windowed,
            chrome: Chrome = .standard,
            titleBar: TitleBar = .standard,
            background: Background = .opaque(.black),
            backgroundEffect: BackgroundEffect = .none,
            level: Level = .normal,
            collectionBehavior: CollectionBehavior = .standard,
            screenPreference: WindowScreenPreference? = nil,
            showsImmediately: Bool = true,
            makeKey: Bool = true,
            hasShadow: Bool = true,
            isResizable: Bool = true,
            allowsMousePassthrough: Bool = false,
            scenePresentation: ScenePresentation = .current
        ) {
            self.title = title
            self.frame = frame
            self.minimumSize = minimumSize
            self.mode = mode
            self.chrome = chrome
            self.titleBar = titleBar
            self.background = background
            self.backgroundEffect = backgroundEffect
            self.level = level
            self.collectionBehavior = collectionBehavior
            self.screenPreference = screenPreference
            self.showsImmediately = showsImmediately
            self.makeKey = makeKey
            self.hasShadow = hasShadow
            self.isResizable = isResizable
            self.allowsMousePassthrough = allowsMousePassthrough
            self.scenePresentation = scenePresentation
        }
    }

    /// Describes which native scene should host a platform window.
    public enum ScenePresentation: Sendable, Equatable {
        /// Present the window in the scene that is currently active.
        case current

        /// Ask the platform to create an independent window scene.
        /// Platforms without window-scene support use their normal window presentation.
        case new
    }

    public enum Chrome: Sendable, Equatable {
        case standard
        case borderless
    }

    public struct TitleBar: Sendable, Equatable {
        public var background: TitleBarBackground
        public var reservesSafeArea: Bool
        public var dragRegionHeight: Float?
        public var trafficLightOffset: Point?

        public static let standard = Self(background: .system, reservesSafeArea: true, dragRegionHeight: nil, trafficLightOffset: nil)
        public static let transparent = Self(background: .transparent, reservesSafeArea: true, dragRegionHeight: nil, trafficLightOffset: nil)
        public static let overlay = Self(background: .transparent, reservesSafeArea: false, dragRegionHeight: 52, trafficLightOffset: nil)

        public init(
            background: TitleBarBackground,
            reservesSafeArea: Bool = true,
            dragRegionHeight: Float? = nil,
            trafficLightOffset: Point? = nil
        ) {
            self.background = background
            self.reservesSafeArea = reservesSafeArea
            self.dragRegionHeight = dragRegionHeight
            self.trafficLightOffset = trafficLightOffset
        }
    }

    public enum TitleBarBackground: Sendable, Equatable {
        case system
        case transparent
    }

    public enum Background: Sendable, Equatable {
        case opaque(Color)
        case transparent

        public var isTransparent: Bool {
            if case .transparent = self {
                return true
            }
            return false
        }
    }

    public enum BackgroundEffect: Sendable, Equatable {
        case none
        case blur(BlurMaterial)

        public enum BlurMaterial: Sendable, Equatable {
            case windowBackground
            case hudWindow
            case sidebar
            case popover
            case contentBackground
            case underWindowBackground

            #if os(macOS)
                case glass
            #endif
        }
    }

    public enum Level: Sendable {
        case normal
        case floating
        case statusBar
    }

    public enum CollectionBehavior: Sendable {
        case standard
        case allSpacesStationary
    }

    public enum Mode: UInt64, Sendable {
        case windowed
        case fullscreen
        case fullScreenWindowed
    }

    nonisolated public static let defaultMinimumSize = Size(width: 800, height: 600)
}

extension Notification.Name {
    public static let adaEngineWindowDidMiniaturize = Notification.Name("AdaEngine.WindowDidMiniaturize")
    public static let adaEngineWindowDidDeminiaturize = Notification.Name("AdaEngine.WindowDidDeminiaturize")
}
