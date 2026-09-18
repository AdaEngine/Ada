//
//  UIAnimationController.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 08.08.2024.
//

import AdaAnimation
import AdaUtils
import Math

enum _AnimationState {
    case idle
    case playing
    case done
}

@MainActor
protocol _AnimationTransaction {
    var state: _AnimationState { get }
    var label: AnyHashable { get }
    mutating func updateAnimation(_ deltaTime: TimeInterval)
}

@MainActor
final class UIAnimationController {
    private(set) var isPlaying: Bool = false

    struct TweenAnimation<T: Animatable>: _AnimationTransaction {
        var state: _AnimationState = .idle
        var animation: Animation
        var label: AnyHashable
        var fromValue: T
        var toValue: T
        var currentValue: T!
        let updateBlock: (T) -> Void
        var currentDuration: TimeInterval = 0
        var animationContext: AnimationContext<T.AnimatableData>

        mutating func updateAnimation(_ deltaTime: TimeInterval) {
            if state == .idle {
                state = .playing
                currentValue = fromValue
            }

            if state == .done {
                return
            }

            self.currentDuration += deltaTime
            if let value = self.animation.base.animate(fromValue.animatableData - toValue.animatableData, time: self.currentDuration, context: &animationContext) {
                currentValue.animatableData = fromValue.animatableData - value
                self.updateBlock(currentValue)
                return
            } else {
                self.updateBlock(toValue)
            }

            self.state = .done
        }

        mutating func shouldMerge(_ tween: TweenAnimation<T>) -> Bool {
            return tween.animation.base.shouldMerge(
                previous: self.animation,
                value: fromValue.animatableData - toValue.animatableData,
                time: self.currentDuration,
                context: &animationContext
            )
        }

        mutating func updateTween(_ tween: TweenAnimation<T>) {
            self.animation = tween.animation
            self.fromValue = tween.fromValue
            self.currentValue = tween.fromValue
            self.toValue = tween.toValue
            self.currentDuration = 0
            self.animationContext = AnimationContext()
            self.state = .idle
        }
    }

    let animation: Animation
    private var transactions: [_AnimationTransaction] = []

    init(animation: Animation) {
        self.animation = animation
    }

    func addTweenAnimation<T: Animatable>(
        from beginValue: T,
        to endValue: T,
        label: AnyHashable,
        environment _: EnvironmentValues,
        updateBlock: @escaping (T) -> Void
    ) {
        let tween = TweenAnimation(
            animation: self.animation,
            label: label,
            fromValue: beginValue,
            toValue: endValue,
            updateBlock: updateBlock,
            animationContext: AnimationContext()
        )

        if let index = self.transactions.firstIndex(where: { $0.label == label }) {
            if var transaction = self.transactions[index] as? TweenAnimation<T> {
                if (transaction.toValue.animatableData - tween.toValue.animatableData).magnitudeSquared == 0 {
                    return
                }

                if transaction.shouldMerge(tween) {
                    transaction.updateTween(tween)
                    transactions[index] = transaction
                } else {
                    self.transactions[index] = tween
                }
            } else {
                // If we add same animation -> remove previous and add a new one.
                self.transactions[index] = tween
            }
        } else {
            self.transactions.append(tween)
        }
    }

    func playAnimation() {
        self.isPlaying = true
    }

    func stopAnimation() {
        self.isPlaying = false
    }

    func update(_ deltaTime: TimeInterval) {
        guard self.isPlaying, !transactions.isEmpty else {
            return
        }

        var index = 0
        while index < transactions.count {
            var transaction = transactions[index]
            transaction.updateAnimation(deltaTime)
            transactions[index] = transaction
            index += 1
        }

        transactions.removeAll(where: { $0.state == .done })

        if transactions.isEmpty {
            self.isPlaying = false
        }
    }
}

extension EnvironmentValues {
    @Entry var animationController: UIAnimationController?
    @Entry var animationsDisabled: Bool = false
}

struct TweenValue<Value: VectorArithmetic>: Animatable {
    var animatableData: Value
}
