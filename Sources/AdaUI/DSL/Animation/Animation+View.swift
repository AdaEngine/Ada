//
//  Animation+View.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 08.08.2024.
//

import AdaAnimation
import AdaUtils
import Math

@MainActor
protocol _AnimationControllerProvider: AnyObject {
    var providedAnimationController: UIAnimationController? { get }
}

/// Performs state changes with an animation transaction.
///
/// Mutations made inside the body rebuild affected views with a transient animation
/// controller. Pass `nil` to disable animation for the body, including inside an
/// outer animated transaction.
@MainActor
public func withAnimation<Result>(
    _ animation: Animation? = .default,
    _ body: () throws -> Result
) rethrows -> Result {
    try BindingAnimationTransaction.withAnimation(animation, body)
}

extension View {
    /// Applies the given animation to this view when the specified value changes.
    /// - Parameter animation: The animation to apply. If animation is nil, the view doesn’t animate.
    /// - Parameter value: A value to monitor for changes.
    @MainActor
    public func animation<V: Equatable>(_ animation: Animation?, value: V) -> some View {
        modifier(_AnimatedViewModifier(content: self, animation: animation, value: value))
    }

    /// Applies the given animation to this view when the specified value changes.
    /// - Parameter animation: The animation to apply.
    /// - Parameter value: A value to monitor for changes.
    @MainActor
    public func animation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        self.animation(Optional(animation), value: value)
    }

    /// Disable any animation for view and their child.
    public func disableAnimation() -> some View {
        self
            .environment(\.animationsDisabled, true)
            .environment(\.animationController, nil)
    }
}

struct _AnimatedViewModifier<Content: View, Value: Equatable>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let animation: Animation?
    let value: Value

    func buildViewNode(in context: BuildContext) -> ViewNode {
        let animationController = animation.map { UIAnimationController(animation: $0) }
        let node = AnimatedViewNode(
            contentNode: context.makeNode(from: content),
            content: content,
            value: self.value,
            animation: animation,
            animationController: animationController
        )

        node.updateEnvironment(context.environment)
        node.invalidateContent()

        return node
    }
}

class AnimatedViewNode<Value: Equatable>: ViewModifierNode {
    var currentValue: Value
    private var animation: Animation?
    private var animationController: UIAnimationController?
    private var retiringControllers: [UIAnimationController] = []

    override var participatesInFrameAnimation: Bool {
        false
    }

    init<Content: View>(
        contentNode: ViewNode,
        content: Content,
        value: Value,
        animation: Animation?,
        animationController: UIAnimationController?
    ) {
        self.currentValue = value
        self.animation = animation
        self.animationController = animationController
        self.animationController?.isDrivenByView = true
        super.init(contentNode: contentNode, content: content)
    }

    override func updateEnvironment(_ environment: EnvironmentValues) {
        var environment = environment
        environment.animationController = environment.animationsDisabled ? nil : self.animationController
        super.updateEnvironment(environment)
    }

    override func update(from newNode: ViewNode) {
        guard let node = newNode as? Self else {
            super.update(from: newNode)
            return
        }

        let valueChanged = node.currentValue != currentValue
        var transaction = UITransactionContext.current ?? Transaction()
        var controller = BindingAnimationTransaction.currentController
        if valueChanged, transaction.disablesAnimations || environment.animationsDisabled {
            animationController?.stopAnimation()
            animationController = nil
            controller = nil
        }
        if valueChanged, !transaction.disablesAnimations, !environment.animationsDisabled {
            transaction.animation = node.animation
            if animationController?.animation != node.animation {
                if let previous = animationController, previous.isPlaying {
                    if node.animation == nil { previous.stopAnimation() } else { retiringControllers.append(previous) }
                }
                animationController = node.animation.map { UIAnimationController(animation: $0) }
                animationController?.isDrivenByView = true
            }
            controller = animationController
        }
        animation = node.animation
        currentValue = node.currentValue
        // Reconciliation must use the mounted controller, not the temporary
        // controller created while evaluating the new view value.
        node.animationController = animationController
        node.updateEnvironment(node.environment)
        if !valueChanged, UITransactionContext.current == nil {
            super.update(from: node)
        } else {
            BindingAnimationTransaction.withController(controller, transaction: transaction) {
                super.update(from: node)
            }
        }
        if valueChanged {
            controller?.playAnimation()
            contentNode.markNeedsLayout()
            markNeedsLayout()
            owner?.containerView?.setNeedsLayout()
        }
    }

    override func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)

        var needsAnotherFrame = false

        if let animationController, animationController.isPlaying {
            animationController.update(deltaTime)
            needsAnotherFrame = true
        }

        for controller in retiringControllers where controller.isPlaying {
            controller.update(deltaTime)
            needsAnotherFrame = true
        }
        retiringControllers.removeAll { !$0.isPlaying }

        if needsAnotherFrame {
            // Runtime redraws are pull-driven via `needsDisplay` / `needsLayout`.
            // Tests advance the tree directly, but the real app only rebuilds render data
            // when a container requests another frame. Without this, tween values update
            // internally while the window stays visually frozen until some unrelated event
            // (for example a resize) triggers layout again.
            owner?.containerView?.setNeedsLayout()
        }
    }
}

extension AnimatedViewNode: _AnimationControllerProvider {
    var providedAnimationController: UIAnimationController? {
        environment.animationsDisabled ? nil : animationController
    }
}
