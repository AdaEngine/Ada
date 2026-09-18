//
//  UIContainerView.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaInput
import AdaUtils
import Math

@MainActor
protocol FocusedInputContainer: AnyObject {
    var hasFocusedInputNode: Bool { get }
}

@MainActor
protocol UIInspectionOverlayStateProviding: AnyObject {
    var inspectionFocusedNode: ViewNode? { get }
    var inspectionHitTestNode: ViewNode? { get }
}

@MainActor
public protocol UIMousePassthroughEventReceiving: AnyObject {
    func uiReceivePassthroughMouseMoved(_ event: MouseEvent)
}

@MainActor
public protocol UIWindowDragRegionResolving: AnyObject {
    func uiAllowsWindowDrag(at windowPoint: Point, with event: MouseEvent) -> Bool
}

/// A container view that contains a view tree.
public final class UIContainerView<Content: View>: UIView, ViewOwner, FocusedInputContainer, UIInspectionOverlayStateProviding, UIMousePassthroughEventReceiving,
    UIWindowDragRegionResolving {
    /// The container view of the container view.
    var containerView: UIView? {
        return self
    }

    var isInspectionRedrawOverlayEnabled: Bool {
        inspectionDebugOverlayMode == .redraw
    }

    /// The view tree of the container view.
    let viewTree: ViewTree<Content>

    var inspectionDebugOverlayMode: UIDebugOverlayMode = .off
    var inspectionRedrawBaselineRevision: UInt64 = ViewNode.currentInspectionRedrawRevision()
    weak var inspectionLastHitTestNode: ViewNode?
    private var transientAnimationControllers: [UIAnimationController] = []
    private var lifecycleActions: [@MainActor () -> Void] = []
    private var isLifecycleFlushScheduled = false

    /// Initialize a new container view.
    ///
    /// - Parameter rootView: The root view of the container view.
    public init(rootView: Content) {
        self.viewTree = ViewTree(
            rootView: rootView,
            environment: UIHotReloadRuntime.initialHostEnvironment ?? EnvironmentValues()
        )
        super.init()
        viewTree.setViewOwner(self)
    }

    /// Layout the subviews.
    ///
    /// - Note: This method is called when the container view is laid out.
    override public func layoutSubviews() {
        super.layoutSubviews()

        var env = rootEnvironmentValues()
        env.navigationBarChromeInsets = navigationBarChromeInsets()
        viewTree.rootNode.mergeEnvironment(env)

        focusManager.setRootNode(viewTree.rootNode)
        let placeRootNode = {
            self.viewTree.rootNode.place(
                in: .zero,
                anchor: .zero,
                proposal: ProposedViewSize(self.frame.size)
            )
        }

        if let animationController = activeTransientAnimationController {
            viewTree.rootNode.performWithTransientAnimationController(animationController, placeRootNode)
        } else {
            placeRootNode()
        }
    }

    private func navigationBarChromeInsets() -> EdgeInsets {
        guard
            let titleBar = window?.configuration.titleBar,
            titleBar.background == .transparent,
            !titleBar.reservesSafeArea
        else {
            return EdgeInsets()
        }

        var insets = EdgeInsets()
        insets.top = titleBar.dragRegionHeight ?? 0

        #if os(macOS)
            let trafficLightOffset = titleBar.trafficLightOffset?.x ?? 0
            insets.leading = 92 + max(trafficLightOffset, 0)
        #endif

        return insets
    }

    /// Build the menu.
    ///
    /// - Parameter builder: The builder to build the menu with.
    override public func buildMenu(with builder: any UIMenuBuilder) {
        viewTree.rootNode.buildMenu(with: builder)
    }

    /// Initialize a new container view.
    ///
    /// - Parameter frame: The frame of the container view.
    @available(*, unavailable, message: "Use init(rootView:) instead.")
    public required init(frame _: Rect) {
        preconditionFailure("Use init(rootView:) instead.")
    }

    /// Hit test the container view.
    ///
    /// - Parameters:
    ///   - point: The point to hit test.
    ///   - event: The event to hit test with.
    /// - Returns: The view that was hit.
    override public func hitTest(_ point: Point, with event: any InputEvent) -> UIView? {
        if self.viewTree.rootNode.hitTest(point, with: event) != nil {
            return self
        }

        return nil
    }

    /// The last on mouse event node.
    private weak var lastOnMouseEventNode: ViewNode?
    /// Mouse-down capture target. Subsequent changed/ended events are routed here.
    private weak var activeMouseEventNode: ViewNode?
    /// Touch-began capture target. Subsequent moved/ended/cancelled events are routed here.
    private var activeTouchEventNodes: [RID: WeakBox<ViewNode>] = [:]
    /// Pinch-began capture target, retained through the end of the gesture.
    private weak var activePinchEventNode: ViewNode?
    /// Manages keyboard-driven focus traversal across focusable nodes.
    let focusManager = UIFocusManager()
    var hasFocusedInputNode: Bool {
        self.focusManager.focusedNode != nil
    }
    var inspectionFocusedNode: ViewNode? {
        self.focusManager.focusedNode
    }
    var inspectionHitTestNode: ViewNode? {
        self.inspectionLastHitTestNode
    }

    // MARK: - Keyboard shortcuts (before focused key dispatch)

    private final class KeyboardShortcutWeakHandle {
        weak var target: (any KeyboardShortcutHandling)?

        init(target: any KeyboardShortcutHandling) {
            self.target = target
        }
    }

    private var keyboardShortcutHandles: [KeyboardShortcutWeakHandle] = []

    /// Handle the mouse event.
    ///
    /// - Parameter event: The mouse event to handle.
    override public func onMouseEvent(_ event: MouseEvent) {
        if event.phase == .began {
            ContextMenuPresentationCenter.dismissForInteraction?(self.window)
        }

        let localPoint = self.convert(event.mousePosition, from: self.window)
        switch event.phase {
        case .began:
            let viewNode = self.viewTree.rootNode.hitTest(localPoint, with: event)
            self.inspectionLastHitTestNode = viewNode
            self.activeMouseEventNode = viewNode
            self.updateFocusedNode(with: viewNode)
            self.routeMouseEvent(event, to: viewNode)
            self.invalidateInspectionOverlayIfNeeded()
        case .changed:
            if event.button != .scrollWheel, let activeMouseEventNode {
                self.routeMouseEvent(event, to: activeMouseEventNode)
            } else if let viewNode = self.viewTree.rootNode.hitTest(localPoint, with: event) {
                self.inspectionLastHitTestNode = viewNode
                self.routeMouseEvent(event, to: viewNode)
                self.invalidateInspectionOverlayIfNeeded()
            } else if lastOnMouseEventNode != nil {
                self.routeMouseEvent(event, to: nil)
            }
        case .ended,
            .cancelled:
            if let activeMouseEventNode {
                self.routeMouseEvent(event, to: activeMouseEventNode)
            } else if let viewNode = self.viewTree.rootNode.hitTest(localPoint, with: event) {
                self.inspectionLastHitTestNode = viewNode
                self.routeMouseEvent(event, to: viewNode)
                self.invalidateInspectionOverlayIfNeeded()
            } else if lastOnMouseEventNode != nil {
                self.routeMouseEvent(event, to: nil)
            }
            self.activeMouseEventNode = nil
        }
    }

    private func routeMouseEvent(_ event: MouseEvent, to viewNode: ViewNode?) {
        if lastOnMouseEventNode !== viewNode {
            lastOnMouseEventNode?.onMouseLeave()
            lastOnMouseEventNode = viewNode
        }

        viewNode?.onMouseEvent(event)
    }

    @_spi(Internal)
    public func uiReceivePassthroughMouseMoved(_ event: MouseEvent) {
        onMouseEvent(event)
    }

    @_spi(Internal)
    public func uiAllowsWindowDrag(at windowPoint: Point, with event: MouseEvent) -> Bool {
        let localPoint = self.convert(windowPoint, from: self.window)
        guard let node = self.viewTree.rootNode.hitTest(localPoint, with: event) else {
            return true
        }

        return !node.blocksWindowDrag
    }

    override public func onKeyEvent(_ event: KeyEvent) {
        if event.status == .down, event.keyCode == .escape {
            if ContextMenuPresentationCenter.dismissAll?() == true {
                return
            }
        }

        if event.keyCode == .tab, event.status == .down {
            if let focusedNode = focusManager.focusedNode as? TextEditorViewNode {
                focusedNode.onKeyEvent(event)
                return
            }

            if event.modifiers.contains(.shift) {
                focusManager.focusPrevious()
            } else {
                focusManager.focusNext()
            }
            self.invalidateInspectionOverlayIfNeeded()
            return
        }

        // Local shortcuts (`.keyboardShortcut`) run before focused controls so navigation keys
        // still work when a ``TextField`` has focus. Remove dead weak entries opportunistically.
        self.keyboardShortcutHandles.removeAll { $0.target == nil }
        for handle in self.keyboardShortcutHandles {
            guard let node = handle.target else {
                continue
            }
            if node.handleShortcutIfNeeded(event: event) {
                return
            }
        }

        if let focusedNode = focusManager.focusedNode {
            focusedNode.onKeyEvent(event)
        } else {
            self.viewTree.rootNode.onReceiveEvent(event)
        }
    }

    override public func onTextInputEvent(_ event: TextInputEvent) {
        if let focusedNode = focusManager.focusedNode {
            focusedNode.onTextInputEvent(event)
        } else {
            self.viewTree.rootNode.onReceiveEvent(event)
        }
    }

    override public func onReceiveEvent(_ event: any InputEvent) {
        if let pinch = event as? PinchEvent {
            if pinch.phase == .began {
                let point = convert(pinch.location, from: window)
                activePinchEventNode = viewTree.rootNode.hitTest(point, with: pinch)
            }
            activePinchEventNode?.onPinchEvent(pinch)
            if pinch.phase == .ended || pinch.phase == .cancelled {
                activePinchEventNode = nil
            }
            return
        }
        self.viewTree.rootNode.onReceiveEvent(event)
    }

    private func updateFocusedNode(with hitNode: ViewNode?) {
        let previousFocusedNode = focusManager.focusedNode
        let newFocusedNode = self.findFocusableNode(from: hitNode)
        focusManager.focus(newFocusedNode)
        if previousFocusedNode !== focusManager.focusedNode {
            self.invalidateInspectionOverlayIfNeeded()
        }
    }

    private func findFocusableNode(from node: ViewNode?) -> ViewNode? {
        var currentNode = node
        while let current = currentNode {
            if current.canBecomeFocused {
                return current
            }
            currentNode = current.parent
        }

        return nil
    }

    /// Update the environment.
    ///
    /// - Parameter env: The environment to update.
    func updateEnvironment(_ env: EnvironmentValues) {
        self.viewTree.rootNode.updateEnvironment(env)
    }

    /// Handle the touches event.
    ///
    /// - Parameter touches: The touches event to handle.
    override public func onTouchesEvent(_ touches: Set<TouchEvent>) {
        for touch in touches {
            let localPoint = convert(touch.location, from: window)
            let node: ViewNode?
            if touch.phase == .began {
                node = viewTree.rootNode.hitTest(localPoint, with: touch)
                if let node {
                    activeTouchEventNodes[touch.contactID] = WeakBox(node)
                }
                updateFocusedNode(with: node)
            } else {
                node =
                    activeTouchEventNodes[touch.contactID]?.value
                    ?? viewTree.rootNode.hitTest(localPoint, with: touch)
            }
            inspectionLastHitTestNode = node
            node?.onTouchesEvent([touch])
            if touch.phase == .ended || touch.phase == .cancelled {
                activeTouchEventNodes.removeValue(forKey: touch.contactID)
            }
            invalidateInspectionOverlayIfNeeded()
        }
    }

    /// Check if the container view is point inside.
    ///
    /// - Parameters:
    ///   - point: The point to check.
    ///   - event: The event to check with.
    /// - Returns: A Boolean value indicating whether the container view is point inside.
    override public func point(inside point: Point, with event: any InputEvent) -> Bool {
        return self.viewTree.rootNode.point(inside: point, with: event)
    }

    /// Draw the container view.
    ///
    /// - Parameters:
    ///   - rect: The rect to draw the container view in.
    ///   - context: The context to draw the container view in.
    override public func draw(in _: Rect, with context: UIGraphicsContext) {
        var context = context
        context.dirtyRect = window?.consumeDirtyRect()
        UILayoutDebugCounters.recordDrawPass()
        viewTree.renderGraph(renderContext: context)
        drawInspectionDebugOverlay(with: context)
        UILayoutDebugCounters.finishFrame()
    }

    /// Update the container view.
    ///
    /// - Parameter deltaTime: The delta time to update the container view with.
    override public func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)
        self.viewTree.rootNode.update(deltaTime)
        self.updateTransientAnimationControllers(deltaTime)
    }

    func addTransientAnimationController(_ animationController: UIAnimationController) {
        if !transientAnimationControllers.contains(where: { $0 === animationController }) {
            transientAnimationControllers.append(animationController)
        }

        animationController.playAnimation()
        setNeedsLayout()
    }

    func enqueueLifecycleAction(_ action: @escaping @MainActor () -> Void) {
        lifecycleActions.append(action)
        scheduleLifecycleFlushIfNeeded()
    }

    private func scheduleLifecycleFlushIfNeeded() {
        guard !isLifecycleFlushScheduled else {
            return
        }

        isLifecycleFlushScheduled = true
        Task { @MainActor in
            self.flushLifecycleActions()
        }
    }

    private func flushLifecycleActions() {
        let actions = lifecycleActions
        lifecycleActions.removeAll(keepingCapacity: true)
        isLifecycleFlushScheduled = false

        for action in actions {
            action()
        }

        if !lifecycleActions.isEmpty {
            scheduleLifecycleFlushIfNeeded()
        }
    }

    private func updateTransientAnimationControllers(_ deltaTime: TimeInterval) {
        var needsAnotherFrame = false

        for animationController in transientAnimationControllers where animationController.isPlaying {
            viewTree.rootNode.performWithTransientAnimationController(animationController) {
                animationController.update(deltaTime)
            }
            if animationController.isPlaying {
                needsAnotherFrame = true
            }
        }

        transientAnimationControllers.removeAll { !$0.isPlaying }

        if needsAnotherFrame {
            setNeedsLayout()
        }
    }

    private var activeTransientAnimationController: UIAnimationController? {
        transientAnimationControllers.first(where: { $0.isPlaying })
    }

    private func drawInspectionDebugOverlay(with context: UIGraphicsContext) {
        guard inspectionDebugOverlayMode != .off else {
            return
        }

        viewTree.rootNode.drawInspectionDebugOverlay(
            with: context,
            mode: inspectionDebugOverlayMode,
            redrawBaselineRevision: inspectionRedrawBaselineRevision,
            focusedNode: focusManager.focusedNode,
            hitTestNode: inspectionLastHitTestNode
        )
    }

    private func invalidateInspectionOverlayIfNeeded() {
        guard inspectionDebugOverlayMode != .off else {
            return
        }
        self.setNeedsDisplay()
    }
}

extension UIView {
    func rootEnvironmentValues() -> EnvironmentValues {
        var env = EnvironmentValues()
        env.safeAreaInsets = rootSafeAreaInsets()
        env.userInterfaceIdiom = userInterfaceIdiom
        env.colorScheme = colorScheme
        env.scaleFactor = window?.screen?.scale ?? Screen.main?.scale ?? 1
        return env
    }

    private func rootSafeAreaInsets() -> EdgeInsets {
        var insets = effectiveSafeAreaInsets
        if let titleBar = window?.configuration.titleBar,
            titleBar.background == .transparent,
            !titleBar.reservesSafeArea {
            insets.top = 0
        }
        return insets
    }
}

extension ViewNode {
    var blocksWindowDrag: Bool {
        switch self {
        case is ButtonViewNode,
            is GestureAreaViewNode,
            is TextFieldViewNode:
            return true
        #if canImport(AppKit) || canImport(UIKit)
            case is NativeViewHostNode:
                return true
        #endif
        default:
            return false
        }
    }
}

extension UIContainerView: KeyboardShortcutRegistering {
    func registerKeyboardShortcut(target: any KeyboardShortcutHandling) {
        let id = ObjectIdentifier(target)
        self.keyboardShortcutHandles.removeAll {
            guard let t = $0.target else {
                return true
            }
            return ObjectIdentifier(t) == id
        }
        self.keyboardShortcutHandles.append(KeyboardShortcutWeakHandle(target: target))
    }

    func unregisterKeyboardShortcut(target: any KeyboardShortcutHandling) {
        let id = ObjectIdentifier(target)
        self.keyboardShortcutHandles.removeAll {
            guard let t = $0.target else {
                return true
            }
            return ObjectIdentifier(t) == id
        }
    }
}
