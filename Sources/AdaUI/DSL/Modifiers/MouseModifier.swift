//
//  MouseModifier.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 02.07.2024.
//

import AdaInput
import Math

extension View {
    public func onHover(perform action: @escaping (Bool) -> Void) -> some View {
        self.modifier(HoverViewModifier(action: action, content: self))
    }

    public func cursorShape(_ shape: Input.CursorShape) -> some View {
        CursorShapeModifier(shape: shape, content: self)
    }

    /// Controls whether this view participates in hit testing.
    public func allowsHitTesting(_ enabled: Bool) -> some View {
        self.modifier(HitTestingModifier(enabled: enabled, content: self))
    }

    /// Invokes an action when the view receives a completed middle mouse click.
    public func onMiddleClick(perform action: @escaping () -> Void) -> some View {
        self.modifier(MiddleClickModifier(action: action, content: self))
    }
}

// MARK: - MiddleClickModifier

private struct MiddleClickModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let action: () -> Void
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        MiddleClickModifierNode(
            action: action,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

private final class MiddleClickModifierNode: ViewModifierNode {
    private var action: () -> Void
    private var isPressed = false

    init<Content: View>(action: @escaping () -> Void, contentNode: ViewNode, content: Content) {
        self.action = action
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? MiddleClickModifierNode else {
            return
        }

        action = node.action
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        guard let mouseEvent = event as? MouseEvent, mouseEvent.button == .middle else {
            return super.hitTest(point, with: event)
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard event.button == .middle else {
            contentNode.onMouseEvent(event)
            return
        }

        switch event.phase {
        case .began:
            isPressed = true
        case .ended:
            if isPressed {
                action()
            }
            isPressed = false
        case .changed:
            break
        case .cancelled:
            isPressed = false
        }
    }

    override func onMouseLeave() {
        isPressed = false
        super.onMouseLeave()
    }
}

// MARK: - HoverViewModifier

struct HoverViewModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let action: (Bool) -> Void
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        HoverViewModifierNode(
            action: action,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

// MARK: - HoverViewModifierNode

final class HoverViewModifierNode: ViewModifierNode {
    override var allowsNestedFrameAnimation: Bool {
        true
    }

    private let action: (Bool) -> Void
    private var isHovered: Bool = false

    init<Content: View>(action: @escaping (Bool) -> Void, contentNode: ViewNode, content: Content) {
        self.action = action
        super.init(contentNode: contentNode, content: content)
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }
        // Observe pointer movement without becoming the target of clicks on nested controls.
        if let mouseEvent = event as? MouseEvent, mouseEvent.button != .none {
            return super.hitTest(point, with: event)
        }
        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        if event.button == .none && event.phase == .changed {
            if !isHovered {
                isHovered = true
                action(true)
            }
        }
        contentNode.onMouseEvent(event)
    }

    override func onMouseLeave() {
        if isHovered {
            isHovered = false
            action(false)
        }
        super.onMouseLeave()
    }
}

// MARK: - HitTestingModifier

private struct HitTestingModifier<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let enabled: Bool
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        HitTestingModifierNode(
            enabled: enabled,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

private final class HitTestingModifierNode: ViewModifierNode {
    private var enabled: Bool

    init<Content: View>(enabled: Bool, contentNode: ViewNode, content: Content) {
        self.enabled = enabled
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? HitTestingModifierNode else {
            return
        }

        enabled = node.enabled
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard enabled else {
            return nil
        }

        return super.hitTest(point, with: event)
    }
}

// MARK: - CursorShapeModifier

struct CursorShapeModifier<Content: View>: View, ViewNodeBuilder {
    typealias Body = Never

    let shape: Input.CursorShape
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        CursorShapeModifierNode(
            shape: self.shape,
            contentNode: context.makeNode(from: content),
            content: content
        )
    }
}

class CursorShapeModifierNode: ViewModifierNode {
    private var shape: Input.CursorShape
    private var isCursorActive = false

    init<Content>(shape: Input.CursorShape, contentNode: ViewNode, content: Content) where Content: View {
        self.shape = shape
        super.init(contentNode: contentNode, content: content)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)

        guard let node = newNode as? CursorShapeModifierNode else {
            return
        }

        shape = node.shape
        if isCursorActive {
            setCursorShape(shape)
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        let newPoint = contentNode.convert(point, from: self)
        guard contentNode.point(inside: newPoint, with: event) else {
            return nil
        }

        return self
    }

    override func onMouseEvent(_ event: MouseEvent) {
        switch event.phase {
        case .began,
            .changed:
            isCursorActive = true
            setCursorShape(shape)
        case .ended,
            .cancelled:
            if absoluteFrame().contains(point: event.mousePosition) {
                isCursorActive = true
                setCursorShape(shape)
            } else {
                resetCursorShape()
            }
        }

        contentNode.onMouseEvent(event)
    }

    override func onMouseLeave() {
        resetCursorShape()
        super.onMouseLeave()
    }

    private func setCursorShape(_ shape: Input.CursorShape) {
        owner?.window?.windowManager.setCursorShape(shape)
    }

    private func resetCursorShape() {
        guard isCursorActive else {
            return
        }

        isCursorActive = false
        owner?.window?.windowManager.setCursorShape(.arrow)
    }
}
