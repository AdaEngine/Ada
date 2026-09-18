//
//  GlassEffectModifier.swift
//  AdaEngine
//

import AdaInput
import Math

extension View {
    /// Applies the Liquid Glass effect to this view using a predefined style.
    ///
    /// The glass element renders behind the view's content, sampling and blurring
    /// the scene below it to produce a frosted-glass appearance.
    ///
    /// ```swift
    /// Text("Hello")
    ///     .padding()
    ///     .glassEffect()
    ///
    /// Text("Hello")
    ///     .padding()
    ///     .glassEffect(.regular, in: .rect(cornerRadius: 16))
    /// ```
    public func glassEffect(_ style: Glass = .regular, in shape: some Shape = CapsuleShape()) -> some View {
        self.modifier(GlassEffectModifier(content: self, configuration: style, shape: shape))
    }
}

struct GlassEffectModifier<Content: View, S: Shape>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let configuration: Glass
    let shape: S

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let contentNode = context.makeNode(from: content)
        let node = GlassEffectViewNode(contentNode: contentNode, content: content)
        node.configuration = configuration
        node.shape = shape
        return node
    }
}

final class GlassEffectViewNode: ViewModifierNode {
    var configuration: Glass = Glass()
    var shape: any Shape = CapsuleShape()
    private var isPressed = false

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)
        applyInteractiveScaleIfNeeded(to: &ctx)

        guard configuration.opacity > 0 else {
            contentNode.draw(with: ctx)
            return
        }

        let scaleFactor = max(ctx.environment.scaleFactor, 1)
        let localFrame = Rect(origin: .zero, size: frame.size)
        let worldTransform = ctx.transform * localFrame.toTransform3D

        var config = configuration
        config.cornerRadius = resolvedCornerRadius()

        ctx.commandQueue.push(
            .drawGlassRect(
                transform: worldTransform,
                halfSize: Vector2(frame.width * 0.5, frame.height * 0.5),
                configuration: config,
                scaleFactor: scaleFactor
            )
        )

        contentNode.draw(with: ctx)
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? GlassEffectViewNode else {
            return
        }
        super.update(from: other)
        self.configuration = other.configuration
        self.shape = other.shape
        if !configuration.isInteractive {
            isPressed = false
        }
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        let newPoint = contentNode.convert(point, from: self)
        if let hitNode = contentNode.hitTest(newPoint, with: event) {
            if configuration.isInteractive, !shouldDeferInteraction(to: hitNode) {
                return self
            }
            return hitNode
        }

        return configuration.isInteractive ? self : nil
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard configuration.isInteractive else {
            contentNode.onMouseEvent(event)
            return
        }

        switch event.phase {
        case .began:
            setPressed(event.button == .left)
        case .changed:
            break
        case .ended,
            .cancelled:
            setPressed(false)
        }
    }

    override func onMouseLeave() {
        setPressed(false)
        contentNode.onMouseLeave()
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard configuration.isInteractive, let touch = touches.first else {
            contentNode.onTouchesEvent(touches)
            return
        }

        switch touch.phase {
        case .began:
            setPressed(true)
        case .moved:
            break
        case .ended,
            .cancelled:
            setPressed(false)
        }
    }

    private func resolvedCornerRadius() -> Float {
        switch shape {
        case is RectangleShape:
            return 0
        case let rounded as RoundedRectangleShape:
            return rounded.cornerRadius
        default:
            return min(frame.width, frame.height) * 0.5
        }
    }

    private func applyInteractiveScaleIfNeeded(to context: inout UIGraphicsContext) {
        guard isPressed, configuration.isInteractive, configuration.interactiveScale != 1 else {
            return
        }

        let anchorPoint = Point(
            x: frame.width * 0.5,
            y: frame.height * 0.5
        )
        let anchorTranslation = Transform3D(translation: [anchorPoint.x, -anchorPoint.y, 0])
        let inverseAnchorTranslation = Transform3D(translation: [-anchorPoint.x, anchorPoint.y, 0])
        let scale = Transform3D(scale: Vector3(configuration.interactiveScale, configuration.interactiveScale, 1))

        context.setTransform(
            context.transform
                * anchorTranslation
                * scale
                * inverseAnchorTranslation
        )
    }

    private func setPressed(_ isPressed: Bool) {
        guard self.isPressed != isPressed else {
            return
        }

        self.isPressed = isPressed
        invalidateNearestLayer()
    }

    private func shouldDeferInteraction(to hitNode: ViewNode) -> Bool {
        switch hitNode {
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
