//
//  UIViewRepresentableNode.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 07.06.2024.
//

import AdaInput
import AdaUtils
import Math

final class UIViewRepresentableNode<Representable: UIViewRepresentable>: ViewNode {
    private(set) var view: Representable.ViewType?
    private var coordinator: Representable.Coordinator
    private(set) var representable: Representable

    init<Content: View>(
        representable: Representable,
        content: Content
    ) {
        self.representable = representable
        self.coordinator = representable.makeCoordinator()
        super.init(content: content)
    }

    override func performLayout() {
        let context = Representable.Context(environment: self.environment, coordinator: coordinator)

        if view == nil {
            self.view = representable.makeUIView(in: context)
        }

        guard let view else {
            return
        }

        view.frame = self.frame
        view.safeAreaInsets = self.environment.safeAreaInsets
        view.userInterfaceIdiom = self.environment.userInterfaceIdiom
        view.colorScheme = self.environment.colorScheme
        self.representable.updateUIView(view, in: context)
        view.layoutSubviews()
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard
            let view, view.isInteractionEnabled, !view.isHidden,
            view.hitTest(point, with: event) != nil
        else {
            return nil
        }
        return self
    }

    override var canBecomeFocused: Bool {
        view?.isInteractionEnabled == true && view?.acceptsKeyboardFocus == true
    }

    override func onFocusChanged(isFocused: Bool) {
        view?.onFocusChanged(isFocused: isFocused)
    }

    override func update(from newNode: ViewNode) {
        super.update(from: newNode)
        guard let newNode = newNode as? UIViewRepresentableNode<Representable> else {
            return
        }
        representable = newNode.representable
        markNeedsLayout()
        owner?.containerView?.setNeedsLayout()
        invalidateNearestLayer()
    }

    override func point(inside point: Point, with event: any InputEvent) -> Bool {
        if let view = self.view, view.point(inside: point, with: event) {
            return true
        }

        return super.point(inside: point, with: event)
    }

    override func sizeThatFits(_ proposal: ProposedViewSize) -> Size {
        guard let view else {
            return proposal.replacingUnspecifiedDimensions()
        }

        let context = Representable.Context(environment: self.environment, coordinator: coordinator)
        return representable.sizeThatFits(proposal, view: view, context: context)
    }

    override func draw(with context: UIGraphicsContext) {
        view?.draw(with: context)
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        guard view?.isInteractionEnabled == true else {
            return
        }
        view?.onEvent(event)
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard view?.isInteractionEnabled == true else {
            return
        }
        view?.onKeyEvent(event)
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        guard view?.isInteractionEnabled == true else {
            return
        }
        view?.onTextInputEvent(event)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard let view, view.isInteractionEnabled else {
            return
        }
        let origin = absoluteFrame().origin
        view.onMouseEvent(
            MouseEvent(
                window: event.window,
                button: event.button,
                scrollDelta: event.scrollDelta,
                mousePosition: event.mousePosition - origin,
                phase: event.phase,
                modifierKeys: event.modifierKeys,
                time: event.time
            )
        )
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard let view, view.isInteractionEnabled else {
            return
        }
        let origin = absoluteFrame().origin
        view.onTouchesEvent(
            Set(
                touches.map { touch in
                    TouchEvent(window: touch.window, location: touch.location - origin, phase: touch.phase, time: touch.time, contactID: touch.contactID)
                }
            )
        )
    }

    override func update(_ deltaTime: TimeInterval) {
        guard let view else {
            return
        }

        view.updateHierarchy(deltaTime)
        if view.consumeNeedsDisplayInHierarchy() {
            owner?.containerView?.setNeedsDisplay(in: absoluteFrame())
        }
    }
}
