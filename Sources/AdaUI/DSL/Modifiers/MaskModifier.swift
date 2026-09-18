//
//  MaskModifier.swift
//  AdaEngine
//
//  Created by Codex on 17.05.2026.
//

import AdaAnimation
import Math

extension View {
    /// Masks this view using the provided shape.
    ///
    /// The shape is resolved in the modified view's local bounds.
    public func mask<S: Shape>(_ shape: S) -> some View {
        self.modifier(MaskShapeModifier(content: self, shape: shape))
    }
}

private struct MaskShapeModifier<Content: View, S: Shape>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let shape: S

    func buildViewNode(in context: BuildContext) -> ViewNode {
        MaskShapeViewNode(
            contentNode: context.makeNode(from: content),
            shape: shape,
            content: content
        )
    }
}

@MainActor
private final class MaskShapeViewNode<S: Shape>: ViewModifierNode {
    private var shape: S
    private var path = Path()

    init<Content: View>(contentNode: ViewNode, shape: S, content: Content) {
        self.shape = shape
        super.init(contentNode: contentNode, content: content)
    }

    override func performLayout() {
        super.performLayout()
        updatePath()
    }

    override func update(from newNode: ViewNode) {
        guard let otherNode = newNode as? Self else {
            super.update(from: newNode)
            return
        }

        let startData = self.shape.animatableData
        let endData = otherNode.shape.animatableData
        let animationController =
            self.environment.animationController
            ?? otherNode.environment.animationController
            ?? nearestAnimationController()

        super.update(from: newNode)

        if let animationController, (startData - endData).magnitudeSquared > 0 {
            self.shape = otherNode.shape
            self.shape.animatableData = startData
            updatePath()

            animationController.addTweenAnimation(
                from: TweenValue(animatableData: startData),
                to: TweenValue(animatableData: endData),
                label: "mask-shape-\(self.id)",
                environment: self.environment,
                updateBlock: { [weak self] value in
                    guard let self else {
                        return
                    }
                    self.shape.animatableData = value.animatableData
                    self.updatePath()
                    self.invalidateNearestLayer()
                    self.owner?.containerView?.setNeedsDisplay(in: self.absoluteFrame())
                }
            )
        } else {
            self.shape = otherNode.shape
            updatePath()
            invalidateNearestLayer()
        }
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.environment = environment

        context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
        if shape is RectangleShape,
            context.pushTransformedClipRect(Rect(origin: .zero, size: frame.size)) {
            contentNode.draw(with: context)
            context.popClipRect()
            return
        }

        context.clip(to: path) { clippedContext in
            contentNode.draw(with: clippedContext)
        }
    }

    private func updatePath() {
        path = shape.path(in: Rect(origin: .zero, size: self.frame.size))
    }
}
