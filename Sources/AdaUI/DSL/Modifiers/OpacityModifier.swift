//
//  OpacityModifier.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 31.07.2024.
//

import Math

extension View {
    public func opacity(_ opacity: Float) -> some View {
        modifier(_OpacityView(opacity: opacity, content: self))
    }
}

struct _OpacityView<Content: View>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let opacity: Float
    let content: Content

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let node = OpacityViewNodeModifier(contentNode: context.makeNode(from: content), content: content)
        node.opacity = opacity
        return node
    }
}

final class OpacityViewNodeModifier: ViewModifierNode {
    var opacity: Float = 1

    override func update(from newNode: ViewNode) {
        let animationController = self.environment.animationController
        super.update(from: newNode)

        guard let node = newNode as? OpacityViewNodeModifier else {
            return
        }

        if let animationController {
            animationController.addTweenAnimation(
                from: TweenValue(animatableData: self.opacity),
                to: TweenValue(animatableData: node.opacity),
                label: self.id,
                environment: self.environment,
                updateBlock: { [weak self] value in
                    self?.opacity = value.animatableData
                    self?.invalidateNearestLayer()
                }
            )
        } else {
            self.opacity = node.opacity
            self.invalidateNearestLayer()
        }
    }

    override func draw(with context: UIGraphicsContext) {
        if let layer {
            var context = context
            context.translateBy(x: self.frame.origin.x, y: -self.frame.origin.y)
            layer.drawLayer(in: context)
        }
    }

    override func performLayout() {
        super.performLayout()
        invalidateLayerIfNeeded()
    }

    override func createLayer() -> UILayer? {
        let layer = UILayer(frame: self.frame) { [weak self] context, _ in
            guard let self else {
                return
            }

            var context = context
            context.opacity *= self.opacity
            self.contentNode.draw(with: context)
        }
        layer.debugLabel = "opacity"
        return layer
    }
}
