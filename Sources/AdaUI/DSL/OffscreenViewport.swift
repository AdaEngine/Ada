//
//  OffscreenViewport.swift
//  AdaEngine
//
//  Created by AdaEngine on 04.04.2026.
//

@_spi(Internal) import AdaInput
@_spi(Internal) import AdaRender
import AdaUtils
import Math

// MARK: - Delegate Protocol

@MainActor
package protocol OffscreenViewportDelegate: AnyObject {
    var renderTexture: Texture2D? { get }
    var renderTextureDidChange: (@MainActor @Sendable () -> Void)? { get set }
    func bootstrapIfNeeded()
    func shutdown()
    func tick(_ deltaTime: AdaUtils.TimeInterval)
    func receiveInputEvent(_ event: any InputEvent)
    func updateMousePosition(_ position: Point)
    func updateSize(_ size: SizeInt, scaleFactor: Float)
}

// MARK: - Viewport View

package struct OffscreenViewportView: View, ViewNodeBuilder {
    package typealias Body = Never

    let delegate: any OffscreenViewportDelegate
    let isInteractive: Bool

    package init(delegate: any OffscreenViewportDelegate, isInteractive: Bool = true) {
        self.delegate = delegate
        self.isInteractive = isInteractive
    }

    func buildViewNode(in _: BuildContext) -> ViewNode {
        OffscreenViewportNode(delegate: delegate, isInteractive: isInteractive, content: self)
    }
}

// MARK: - Container View

package struct OffscreenViewportContainer<Content: View>: View, ViewNodeBuilder {
    package typealias Body = Never

    let delegateFactory: @MainActor () -> any OffscreenViewportDelegate
    let contentBuilder: @MainActor (any OffscreenViewportDelegate) -> Content

    package init(
        delegateFactory: @escaping @MainActor () -> any OffscreenViewportDelegate,
        @ViewBuilder contentBuilder: @escaping @MainActor (any OffscreenViewportDelegate) -> Content
    ) {
        self.delegateFactory = delegateFactory
        self.contentBuilder = contentBuilder
    }

    func buildViewNode(in _: BuildContext) -> ViewNode {
        OffscreenViewportContainerNode(
            delegateFactory: delegateFactory,
            contentBuilder: contentBuilder,
            content: self
        )
    }
}

// MARK: - Viewport ViewNode

@MainActor
private final class OffscreenViewportNode: ViewNode {
    private let viewportRenderer: any OffscreenViewportDelegate
    private var lastReportedSize: SizeInt = .zero
    private var isActive = false
    private var didBootstrap = false
    private var isInteractive: Bool
    private var pressedKeys: [KeyCode: KeyEvent] = [:]
    private var pressedMouse: MouseEvent?
    private var activeTouches: [RID: TouchEvent] = [:]

    private static weak var currentActiveViewport: OffscreenViewportNode?

    override var participatesInFrameAnimation: Bool {
        false
    }

    init<C: View>(delegate: any OffscreenViewportDelegate, isInteractive: Bool, content: C) {
        self.viewportRenderer = delegate
        self.isInteractive = isInteractive
        super.init(content: content)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? OffscreenViewportNode else {
            super.update(from: newNode)
            return
        }
        if isInteractive && !other.isInteractive {
            cancelActiveInput()
        }
        isInteractive = other.isInteractive
        super.update(from: newNode)
    }

    // MARK: Layout

    override func performLayout() {
        super.performLayout()

        if !didBootstrap {
            didBootstrap = true
            viewportRenderer.bootstrapIfNeeded()
        }

        let size = frame.size
        let environmentScale = environment.scaleFactor
        guard
            size.width.isFinite,
            size.height.isFinite,
            environmentScale.isFinite
        else {
            return
        }

        let scale = max(environmentScale, 1)
        let pixelWidth = size.width * scale
        let pixelHeight = size.height * scale
        guard
            pixelWidth.isFinite,
            pixelHeight.isFinite,
            pixelWidth > 0,
            pixelHeight > 0,
            pixelWidth <= Float(Int32.max),
            pixelHeight <= Float(Int32.max)
        else {
            return
        }

        let pixelSize = SizeInt(
            width: Int(pixelWidth.rounded()),
            height: Int(pixelHeight.rounded())
        )

        guard pixelSize.width > 0 && pixelSize.height > 0 else {
            return
        }

        if pixelSize != lastReportedSize {
            lastReportedSize = pixelSize
            viewportRenderer.updateSize(pixelSize, scaleFactor: scale)
        }
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        return proposal.replacingUnspecifiedDimensions()
    }

    // MARK: Tick

    override func update(_ deltaTime: AdaUtils.TimeInterval) {
        viewportRenderer.tick(deltaTime)
    }

    // MARK: Draw

    override func draw(with context: UIGraphicsContext) {
        guard let texture = viewportRenderer.renderTexture else {
            super.draw(with: context)
            return
        }

        var context = context
        context.environment = environment
        context.pushClipRect(absoluteFrame())
        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        let rect = Rect(origin: .zero, size: frame.size)
        context.drawRect(rect, texture: texture, color: .white)
        context.popClipRect()
    }

    // MARK: Input

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard isInteractive, self.point(inside: point, with: event) else {
            return nil
        }
        return self
    }

    override func point(inside point: Point, with _: any InputEvent) -> Bool {
        let size = frame.size
        return point.x >= 0 && point.y >= 0 && point.x <= size.width && point.y <= size.height
    }

    override func onPinchEvent(_ event: PinchEvent) {
        guard isInteractive else { return }
        if event.phase == .began {
            activateViewport()
        }
        viewportRenderer.receiveInputEvent(
            PinchEvent(
                window: event.window,
                location: viewportLocalPosition(event.location),
                scale: event.scale,
                phase: event.phase,
                time: event.time
            )
        )
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard isInteractive else { return }
        let localPosition = viewportLocalPosition(event.mousePosition)
        let localEvent = MouseEvent(
            window: event.window,
            button: event.button,
            scrollDelta: event.scrollDelta,
            mousePosition: localPosition,
            phase: event.phase,
            modifierKeys: event.modifierKeys,
            time: event.time
        )

        if event.phase == .began {
            activateViewport()
            pressedMouse = localEvent
        } else if event.phase == .ended || event.phase == .cancelled {
            pressedMouse = nil
        }

        viewportRenderer.updateMousePosition(localPosition)
        viewportRenderer.receiveInputEvent(localEvent)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard isInteractive else { return }
        if touches.contains(where: { $0.phase == .began }) {
            activateViewport()
        }

        for touch in touches {
            let localPosition = viewportLocalPosition(touch.location)
            let localTouch = TouchEvent(
                window: touch.window,
                location: localPosition,
                phase: touch.phase,
                time: touch.time,
                contactID: touch.contactID
            )
            if touch.phase == .began || touch.phase == .moved {
                activeTouches[touch.contactID] = localTouch
            } else {
                activeTouches[touch.contactID] = nil
            }
            viewportRenderer.receiveInputEvent(localTouch)
        }
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard isActive, isInteractive else {
            return
        }
        if event.status == .down {
            pressedKeys[event.keyCode] = event
        } else {
            pressedKeys[event.keyCode] = nil
        }
        viewportRenderer.receiveInputEvent(event)
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        guard isActive, isInteractive else {
            return
        }
        viewportRenderer.receiveInputEvent(event)
    }

    override var canBecomeFocused: Bool { isInteractive }

    override func onFocusChanged(isFocused: Bool) {
        if !isFocused && isActive {
            cancelActiveInput()
        }
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        if parent == nil, Self.currentActiveViewport === self {
            cancelActiveInput()
            isActive = false
            Self.currentActiveViewport = nil
        }
    }

    private func cancelActiveInput() {
        for event in pressedKeys.values {
            viewportRenderer.receiveInputEvent(
                KeyEvent(window: event.window, keyCode: event.keyCode, modifiers: event.modifiers, status: .up, time: event.time, isRepeated: false)
            )
        }
        pressedKeys.removeAll()
        if let event = pressedMouse {
            viewportRenderer.receiveInputEvent(
                MouseEvent(
                    window: event.window,
                    button: event.button,
                    mousePosition: event.mousePosition,
                    phase: .cancelled,
                    modifierKeys: event.modifierKeys,
                    time: event.time
                )
            )
            pressedMouse = nil
        }
        for touch in activeTouches.values {
            viewportRenderer.receiveInputEvent(
                TouchEvent(window: touch.window, location: touch.location, phase: .cancelled, time: touch.time, contactID: touch.contactID)
            )
        }
        activeTouches.removeAll()
        isActive = false
        if Self.currentActiveViewport === self { Self.currentActiveViewport = nil }
    }

    // MARK: Private

    private func viewportLocalPosition(_ windowPosition: Point) -> Point {
        let absoluteOrigin = absoluteFrame().origin
        return Point(
            x: windowPosition.x - absoluteOrigin.x,
            y: windowPosition.y - absoluteOrigin.y
        )
    }

    private func activateViewport() {
        if let previous = Self.currentActiveViewport, previous !== self {
            previous.cancelActiveInput()
        }
        isActive = true
        Self.currentActiveViewport = self
    }
}

// MARK: - Container ViewNode

@MainActor
private final class OffscreenViewportContainerNode<Content: View>: ViewContainerNode {
    private var viewportRenderer: (any OffscreenViewportDelegate)?
    private var delegateFactory: @MainActor () -> any OffscreenViewportDelegate
    private var contentBuilder: @MainActor (any OffscreenViewportDelegate) -> Content

    override var participatesInFrameAnimation: Bool {
        false
    }

    init<Root: View>(
        delegateFactory: @escaping @MainActor () -> any OffscreenViewportDelegate,
        contentBuilder: @escaping @MainActor (any OffscreenViewportDelegate) -> Content,
        content: Root
    ) {
        self.delegateFactory = delegateFactory
        self.contentBuilder = contentBuilder
        super.init(content: content, nodes: [])
    }

    override func performLayout() {
        if viewportRenderer == nil {
            invalidateContent()
        }

        super.performLayout()
    }

    override func invalidateContent() {
        if viewportRenderer == nil {
            viewportRenderer = delegateFactory()
            viewportRenderer?.renderTextureDidChange = { [weak self] in
                guard let self else {
                    return
                }
                self.invalidateContent()
                self.owner?.containerView?.setNeedsDisplay(in: self.absoluteFrame())
            }
        }

        guard let viewportRenderer else {
            return
        }
        let view = contentBuilder(viewportRenderer)
        let inputs = _ViewInputs(parentNode: self, environment: self.environment)
        let outputs =
            Content._makeListView(
                _ViewGraphNode(value: view),
                inputs: _ViewListInputs(input: inputs)
            )
            .outputs
        let nodes = outputs.map(\.node)

        reconcileChildNodes(from: nodes)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? OffscreenViewportContainerNode<Content> else {
            super.update(from: newNode)
            return
        }
        self.environmentTransform = other.environmentTransform
        self.applyResolvedEnvironmentSilently(other.environment)
        self.setContent(other.content)
        self.delegateFactory = other.delegateFactory
        self.contentBuilder = other.contentBuilder
        self.invalidateContent()
    }

    override func didMove(to parent: ViewNode?) {
        super.didMove(to: parent)
        guard parent == nil else {
            return
        }
        shutdownDelegate()
    }

    private func shutdownDelegate() {
        viewportRenderer?.shutdown()
        viewportRenderer = nil
    }
}
