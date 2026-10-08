//
//  ViewTester.swift
//  AdaEngineTests
//
//  Created by vladislav.prusakov on 09.08.2024.
//

import Math
@testable import AdaUI
@testable import AdaPlatform
import AdaInput
import AdaUtils

/// Object that test view
@MainActor
class ViewTester<Content: View> {

    let containerView: UIContainerView<Content>
    var size: Size = .zero

    /// Creates a tester with a concrete root view instance.
    ///
    /// The helper allocates `UIContainerView`, applies a default frame, and
    /// performs an initial layout pass.
    ///
    /// - Parameter rootView: Root view to mount into test container.
    init(rootView: Content) {
        self.containerView = UIContainerView(rootView: rootView)
        self.containerView.frame.size = Size(width: 800, height: 600)
        self.containerView.layoutSubviews()
    }

    /// Creates a tester using a view builder closure.
    ///
    /// - Parameter rootView: Builder that returns the root view.
    convenience init(@ViewBuilder rootView: () -> Content) {
        self.init(rootView: rootView())
    }

    /// Updates container size used for layout and hit-testing.
    ///
    /// - Parameter size: New frame size for the root container.
    /// - Returns: Self for fluent chaining.
    @discardableResult
    func setSize(_ size: Size) -> Self {
        self.size = size
        self.containerView.frame.size = size
        self.containerView.viewTree.rootNode.invalidateContent()
        return self
    }

    /// Forces an explicit layout pass on the container.
    ///
    /// - Returns: Self for fluent chaining.
    @discardableResult
    func performLayout() -> Self {
        self.containerView.layoutSubviews()
        return self
    }

    /// Invalidates root node content and triggers tree rebuild logic.
    ///
    /// - Returns: Self for fluent chaining.
    @discardableResult
    func invalidateContent() -> Self {
        self.containerView.viewTree.rootNode.invalidateContent()
        return self
    }

    /// Finds a node by the value provided via `.id(...)`.
    ///
    /// - Parameter id: Identifier value attached to a node.
    /// - Returns: Matching node if found.
    func findNodeById<H: Hashable>(_ id: H) -> ViewNode? {
        return self.containerView.viewTree.rootNode.findNodeById(id)
    }

    /// Finds a node by accessibility identifier.
    ///
    /// - Parameter id: String identifier from `.accessibilityIdentifier(...)`.
    /// - Returns: Matching node if found.
    func findNodeByAccessibilityIdentifier(_ id: String) -> ViewNode? {
        return self.containerView.viewTree.rootNode.findNodyByAccessibilityIdentifier(id)
    }

    // MARK: Interaction

    /// Performs hit-testing at the given point with a synthesized left-mouse event.
    ///
    /// - Parameters:
    ///   - point: Point in container coordinates.
    ///   - phase: Mouse event phase used to build the event.
    /// - Returns: Node returned by `hitTest`.
    func click(at point: Point, phase: MouseEvent.Phase = .began) -> ViewNode? {
        let event = makeMouseEvent(
            at: point,
            button: .left,
            phase: phase,
            scrollDelta: .zero,
            modifierKeys: [],
            time: 0
        )

        return self.hitTest(point, event: event)
    }

    /// Sends a synthesized mouse event through hit-test and dispatch routing.
    ///
    /// The helper mimics `UIContainerView` routing, including mouse capture
    /// between `.began` and `.ended`.
    ///
    /// - Parameters:
    ///   - point: Point in container coordinates.
    ///   - button: Mouse button for the event.
    ///   - phase: Event phase.
    ///   - scrollDelta: Wheel delta for scroll events.
    ///   - time: Event timestamp used by gesture/scroll logic.
    /// - Returns: Hit-tested node at `point` for this event.
    @discardableResult
    func sendMouseEvent(
        at point: Point,
        button: MouseButton = .left,
        phase: MouseEvent.Phase,
        scrollDelta: Point = .zero,
        modifierKeys: KeyModifier = [],
        time: Float = 0
    ) -> ViewNode? {
        let event = makeMouseEvent(
            at: point,
            button: button,
            phase: phase,
            scrollDelta: scrollDelta,
            modifierKeys: modifierKeys,
            time: time
        )

        let node = self.hitTest(point, event: event)
        dispatchMouseEvent(event, hitNode: node)
        return node
    }

    /// Routes hit-testing directly to root node.
    ///
    /// - Parameters:
    ///   - point: Point in container coordinates.
    ///   - event: Input event used for hit-testing.
    /// - Returns: Hit-tested node if any.
    func hitTest(_ point: Point, event: any InputEvent) -> ViewNode? {
        self.containerView.viewTree.rootNode.hitTest(point, with: event)
    }

    /// Returns a debug trace of the hit node and all of its parents.
    ///
    /// - Parameters:
    ///   - point: Point in container coordinates.
    ///   - button: Mouse button used to build the probing event.
    ///   - phase: Event phase used to build the probing event.
    /// - Returns: Ordered path from hit node to root node.
    func hitPath(
        at point: Point,
        button: MouseButton = .left,
        phase: MouseEvent.Phase = .began
    ) -> [String] {
        let event = makeMouseEvent(
            at: point,
            button: button,
            phase: phase,
            scrollDelta: .zero,
            modifierKeys: [],
            time: 0
        )

        var path: [String] = []
        var currentNode = self.hitTest(point, event: event)
        while let node = currentNode {
            let identifier = node.accessibilityIdentifier ?? "nil"
            path.append("\(type(of: node)) [id=\(identifier)] frame=\(node.frame)")
            currentNode = node.parent
        }
        return path
    }

    /// Searches a rectangle for a point that hits the given accessibility identifier.
    ///
    /// The method scans the area with a grid step and returns the first matching point.
    ///
    /// - Parameters:
    ///   - identifier: Target accessibility identifier.
    ///   - rect: Search area in container coordinates.
    ///   - step: Grid step in points. Must be greater than zero.
    /// - Returns: First point that hits `identifier`, or `nil`.
    func findHitPoint(
        forAccessibilityIdentifier identifier: String,
        in rect: Rect,
        step: Float = 4
    ) -> Point? {
        guard step > 0 else {
            return nil
        }

        var y = rect.minY
        while y <= rect.maxY {
            var x = rect.minX
            while x <= rect.maxX {
                let point = Point(x, y)
                if let hitNode = self.click(at: point),
                   nearestAccessibilityIdentifier(from: hitNode) == identifier {
                    return point
                }

                x += step
            }
            y += step
        }

        return nil
    }

    /// Collects all accessibility identifiers that are hittable in a rectangle.
    ///
    /// - Parameters:
    ///   - rect: Search area in container coordinates.
    ///   - step: Grid step in points. Must be greater than zero.
    /// - Returns: Unique set of identifiers reachable by hit-testing.
    func collectHitAccessibilityIdentifiers(
        in rect: Rect,
        step: Float = 12
    ) -> Set<String> {
        guard step > 0 else {
            return []
        }

        var identifiers: Set<String> = []
        var y = rect.minY
        while y <= rect.maxY {
            var x = rect.minX
            while x <= rect.maxX {
                let point = Point(x, y)
                if let hitNode = self.click(at: point),
                   let identifier = nearestAccessibilityIdentifier(from: hitNode) {
                    identifiers.insert(identifier)
                }

                x += step
            }
            y += step
        }

        return identifiers
    }

    /// Walks up parent chain to find the closest accessibility identifier.
    ///
    /// - Parameter node: Start node from hit-testing result.
    /// - Returns: First non-nil identifier in ancestry, or `nil`.
    private func nearestAccessibilityIdentifier(from node: ViewNode?) -> String? {
        var currentNode = node
        while let node = currentNode {
            if let identifier = node.accessibilityIdentifier {
                return identifier
            }
            currentNode = node.parent
        }
        return nil
    }

    /// Creates a synthetic mouse event for tests.
    ///
    /// - Parameters:
    ///   - point: Mouse position in container coordinates.
    ///   - button: Mouse button.
    ///   - phase: Event phase.
    ///   - scrollDelta: Wheel delta.
    ///   - time: Event timestamp.
    /// - Returns: Configured `MouseEvent`.
    private func makeMouseEvent(
        at point: Point,
        button: MouseButton,
        phase: MouseEvent.Phase,
        scrollDelta: Point,
        modifierKeys: KeyModifier,
        time: Float
    ) -> MouseEvent {
        MouseEvent(
            window: .empty,
            button: button,
            scrollDelta: scrollDelta,
            mousePosition: point,
            phase: phase,
            modifierKeys: modifierKeys,
            time: time
        )
    }

    /// Dispatches mouse event to a hit node using container-like routing rules.
    ///
    /// - Parameters:
    ///   - event: Event to dispatch.
    ///   - hitNode: Node returned by hit-testing for this event.
    private func dispatchMouseEvent(_ event: MouseEvent, hitNode: ViewNode?) {
        _ = hitNode
        self.containerView.onMouseEvent(event)
    }

    @discardableResult
    func sendKeyEvent(
        _ keyCode: KeyCode,
        modifiers: KeyModifier = [],
        status: KeyEvent.Status = .down,
        isRepeated: Bool = false,
        time: Float = 0
    ) -> Self {
        let event = KeyEvent(
            window: .empty,
            keyCode: keyCode,
            modifiers: modifiers,
            status: status,
            time: time,
            isRepeated: isRepeated
        )

        self.containerView.onKeyEvent(event)
        return self
    }

    @discardableResult
    func sendTextInput(_ text: String, time: Float = 0) -> Self {
        let event = TextInputEvent(
            window: .empty,
            text: text,
            action: .insert,
            time: time
        )

        self.containerView.onTextInputEvent(event)
        return self
    }

    @discardableResult
    func sendDeleteBackward(time: Float = 0) -> Self {
        let event = TextInputEvent(
            window: .empty,
            text: "",
            action: .deleteBackward,
            time: time
        )

        self.containerView.onTextInputEvent(event)
        return self
    }

    // MARK: Simulations

    /// Placeholder for render-frame simulation used by legacy tests.
    ///
    /// - Returns: Self for fluent chaining.
    @discardableResult
    func simulateRenderOneFrame() -> Self {
//        let context = UIGraphicsContext(window: UIWindow())
//        self.containerView.draw(in: Rect(origin: .zero, size: self.size), with: context)
        return self
    }

    /// Advances the mounted view tree by one update tick.
    ///
    /// - Parameter deltaTime: Frame delta to pass into the UI update loop.
    /// - Returns: Self for fluent chaining.
    @discardableResult
    func advanceFrame(deltaTime: TimeInterval) -> Self {
        self.containerView.internalUpdate(deltaTime)
        return self
    }
}
