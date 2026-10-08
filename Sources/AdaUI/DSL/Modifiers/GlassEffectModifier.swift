//
//  GlassEffectModifier.swift
//  AdaEngine
//

import AdaInput
import AdaUtils
import Math

extension View {
    /// Applies the Liquid Glass effect to this view using a predefined style.
    ///
    /// The glass element renders behind the view's content, sampling and blurring
    /// the scene below it to produce a frosted-glass appearance. Visible glass
    /// responds to press and drag by default; use `.interactive(false)` to disable it.
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
    private var dragStart: Point?
    private var dragOffset: Point = .zero
    private var presentationOffset: Point = .zero
    private var releaseVelocity: Point = .zero
    private var presentationScale: Float = 1
    private var scaleVelocity: Float = 0
    private var activeTouchID: RID?

    var respondsToInteraction: Bool {
        configuration.isInteractive && configuration.opacity > 0
    }

    override func draw(with context: UIGraphicsContext) {
        var ctx = context
        ctx.translateBy(x: frame.origin.x, y: -frame.origin.y)
        applyInteractiveTransformIfNeeded(to: &ctx)

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
        if !respondsToInteraction {
            isPressed = false
            dragStart = nil
            dragOffset = .zero
            presentationOffset = .zero
            releaseVelocity = .zero
            presentationScale = 1
            scaleVelocity = 0
            activeTouchID = nil
        }
    }

    func setButtonInteraction(start: Point?, location: Point?) {
        guard respondsToInteraction else {
            return
        }

        let newOffset: Point
        if let start, let location {
            newOffset = Point(x: location.x - start.x, y: location.y - start.y)
        } else {
            newOffset = .zero
        }
        let newIsPressed = start != nil && location != nil
        guard isPressed != newIsPressed || dragOffset != newOffset else {
            return
        }

        if newIsPressed && !isPressed {
            beginPressScale()
        }
        isPressed = newIsPressed
        dragOffset = newOffset
        if newIsPressed {
            presentationOffset = boundedOffset(newOffset)
            releaseVelocity = .zero
        }
        invalidateInteractivePresentation()
    }

    override func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)
        guard respondsToInteraction else {
            return
        }

        let targetScale = isPressed ? configuration.interactiveScale : 1
        let needsOffsetSpring = !isPressed && presentationOffset != .zero
        let needsScaleSpring = abs(presentationScale - targetScale) > 0.0001 || abs(scaleVelocity) > 0.001
        guard needsOffsetSpring || needsScaleSpring else {
            return
        }

        let step = min(max(deltaTime, 0), 1 / 30)
        guard step > 0 else {
            return
        }
        let stiffness: Float = 190
        let damping: Float = 21
        if needsOffsetSpring {
            let acceleration = Point(
                x: -stiffness * presentationOffset.x - damping * releaseVelocity.x,
                y: -stiffness * presentationOffset.y - damping * releaseVelocity.y
            )
            releaseVelocity = Point(
                x: releaseVelocity.x + acceleration.x * step,
                y: releaseVelocity.y + acceleration.y * step
            )
            presentationOffset = Point(
                x: presentationOffset.x + releaseVelocity.x * step,
                y: presentationOffset.y + releaseVelocity.y * step
            )
            if abs(presentationOffset.x) < 0.1, abs(presentationOffset.y) < 0.1,
                abs(releaseVelocity.x) < 0.5, abs(releaseVelocity.y) < 0.5 {
                presentationOffset = .zero
                releaseVelocity = .zero
            }
        }
        if needsScaleSpring {
            let acceleration = stiffness * (targetScale - presentationScale) - damping * scaleVelocity
            scaleVelocity += acceleration * step
            presentationScale += scaleVelocity * step
            if abs(presentationScale - targetScale) < 0.0001, abs(scaleVelocity) < 0.001 {
                presentationScale = targetScale
                scaleVelocity = 0
            }
        }
        invalidateInteractivePresentation()
    }

    override func hitTest(_ point: Point, with event: any InputEvent) -> ViewNode? {
        guard self.point(inside: point, with: event) else {
            return nil
        }

        let newPoint = contentNode.convert(point, from: self)
        if let hitNode = contentNode.hitTest(newPoint, with: event) {
            return hitNode
        }

        return respondsToInteraction ? self : nil
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard respondsToInteraction else {
            contentNode.onMouseEvent(event)
            return
        }

        switch event.phase {
        case .began:
            dragStart = event.mousePosition
            dragOffset = .zero
            presentationOffset = .zero
            releaseVelocity = .zero
            setPressed(event.button == .left)
        case .changed:
            guard isPressed, event.button == .left, let dragStart else {
                break
            }
            dragOffset = Point(
                x: event.mousePosition.x - dragStart.x,
                y: event.mousePosition.y - dragStart.y
            )
            presentationOffset = boundedOffset(dragOffset)
            releaseVelocity = .zero
            invalidateInteractivePresentation()
        case .ended,
            .cancelled:
            dragStart = nil
            dragOffset = .zero
            setPressed(false)
        }
    }

    override func onMouseLeave() {
        dragStart = nil
        dragOffset = .zero
        setPressed(false)
        contentNode.onMouseLeave()
    }

    func cancelObservedMouseInteraction() {
        dragStart = nil
        dragOffset = .zero
        setPressed(false)
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard respondsToInteraction, let touch = touches.first else {
            contentNode.onTouchesEvent(touches)
            return
        }

        switch touch.phase {
        case .began:
            guard activeTouchID == nil else {
                contentNode.onTouchesEvent(touches)
                return
            }
            activeTouchID = touch.contactID
            dragStart = touch.location
            dragOffset = .zero
            presentationOffset = .zero
            releaseVelocity = .zero
            setPressed(true)
        case .moved:
            guard touch.contactID == activeTouchID, let dragStart else {
                break
            }
            dragOffset = Point(
                x: touch.location.x - dragStart.x,
                y: touch.location.y - dragStart.y
            )
            presentationOffset = boundedOffset(dragOffset)
            releaseVelocity = .zero
            invalidateInteractivePresentation()
        case .ended,
            .cancelled:
            guard touch.contactID == activeTouchID else {
                break
            }
            activeTouchID = nil
            dragStart = nil
            dragOffset = .zero
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

    private func applyInteractiveTransformIfNeeded(to context: inout UIGraphicsContext) {
        guard respondsToInteraction, isPressed || presentationOffset != .zero || presentationScale != 1 else {
            return
        }

        let distance = (presentationOffset.x * presentationOffset.x + presentationOffset.y * presentationOffset.y).squareRoot()
        let direction = distance > 0
            ? Point(x: presentationOffset.x / distance, y: presentationOffset.y / distance)
            : Point(x: 1, y: 0)
        let projectedSize = max(abs(direction.x) * frame.width + abs(direction.y) * frame.height, 1)
        let stretchLimit = min(projectedSize * 0.35, 28)
        let elasticDistance = distance * stretchLimit / (stretchLimit * stretchLimit + distance * distance).squareRoot()
        let stretch = elasticDistance / projectedSize * resolvedStretchStrength
        let baseScale = presentationScale
        let rotationAngle = atan2(-direction.y, direction.x)
        let rotation = Transform3D(quat: Quat(axis: Vector3(0, 0, 1), angle: rotationAngle))
        let inverseRotation = Transform3D(quat: Quat(axis: Vector3(0, 0, 1), angle: -rotationAngle))
        let projectedHalfSize = projectedSize * 0.5
        let anchorPoint = Point(
            x: frame.width * 0.5 - (distance > 0 ? direction.x * projectedHalfSize : 0),
            y: frame.height * 0.5 - (distance > 0 ? direction.y * projectedHalfSize : 0)
        )
        let anchorTranslation = Transform3D(translation: [anchorPoint.x, -anchorPoint.y, 0])
        let inverseAnchorTranslation = Transform3D(translation: [-anchorPoint.x, anchorPoint.y, 0])
        let followTranslation = Transform3D(translation: [
            presentationOffset.x * 0.5 * resolvedStretchStrength,
            -presentationOffset.y * 0.5 * resolvedStretchStrength,
            0
        ])
        let perpendicularScale = 1 - 0.12 * stretch / (1 + stretch)
        let scale = Transform3D(scale: Vector3(baseScale * (1 + stretch), baseScale * perpendicularScale, 1))

        context.setTransform(
            context.transform
                * followTranslation
                * anchorTranslation
                * rotation
                * scale
                * inverseRotation
                * inverseAnchorTranslation
        )
    }

    private func setPressed(_ isPressed: Bool) {
        guard self.isPressed != isPressed else {
            return
        }

        if isPressed {
            beginPressScale()
        }
        self.isPressed = isPressed
        invalidateInteractivePresentation()
    }

    private func beginPressScale() {
        let initialScale = 1 + (configuration.interactiveScale - 1) * 0.5
        if configuration.interactiveScale >= 1 {
            presentationScale = max(presentationScale, initialScale)
        } else {
            presentationScale = min(presentationScale, initialScale)
        }
        scaleVelocity = 0
    }

    private func boundedOffset(_ offset: Point) -> Point {
        guard resolvedStretchStrength > 0 else {
            return .zero
        }
        let distance = (offset.x * offset.x + offset.y * offset.y).squareRoot()
        guard distance > 0 else {
            return .zero
        }
        let direction = Point(x: offset.x / distance, y: offset.y / distance)
        let projectedSize = max(abs(direction.x) * frame.width + abs(direction.y) * frame.height, 1)
        let limit = min(max(projectedSize * 0.8, 24), 72)
        let boundedDistance = distance * limit / (limit * limit + distance * distance).squareRoot()
        return Point(x: direction.x * boundedDistance, y: direction.y * boundedDistance)
    }

    private var resolvedStretchStrength: Float {
        min(max(configuration.stretchStrength, 0), 1)
    }

    private func invalidateInteractivePresentation() {
        invalidateNearestLayer()
        let bounds = visualAbsoluteFrame()
        let extraX = frame.width + abs(presentationOffset.x) * 2
        let extraY = frame.height + abs(presentationOffset.y) * 2
        owner?.containerView?.setNeedsDisplay(in: Rect(
            x: bounds.minX - extraX,
            y: bounds.minY - extraY,
            width: bounds.width + extraX * 2,
            height: bounds.height + extraY * 2
        ))
    }

}
