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
    /// View-owned controllers must not also be advanced by the container clock.
    var isDrivenByView = false

    struct TweenAnimation<T: Animatable>: _AnimationTransaction {
        var state: _AnimationState = .idle
        var animation: Animation
        var label: AnyHashable
        var fromValue: T
        var toValue: T
        var currentValue: T!
        var updateBlock: (T) -> Void
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
            self.updateBlock = tween.updateBlock
            self.currentDuration = 0
            self.animationContext = AnimationContext()
            self.state = .idle
        }
    }

    let animation: Animation

    private struct TransactionEntry {
        var transaction: any _AnimationTransaction
        let revision: UInt64
    }

    private var transactions: [TransactionEntry] = []
    private var transactionRevision: UInt64 = 0
    private var isUpdating = false

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

        if let index = self.transactions.firstIndex(where: { $0.transaction.label == label }) {
            if var transaction = self.transactions[index].transaction as? TweenAnimation<T> {
                if (transaction.toValue.animatableData - tween.toValue.animatableData).magnitudeSquared == 0 {
                    return
                }

                if transaction.shouldMerge(tween) {
                    transaction.updateTween(tween)
                    transactions[index] = makeEntry(transaction)
                } else {
                    self.transactions[index] = makeEntry(tween)
                }
            } else {
                // If we add same animation -> remove previous and add a new one.
                self.transactions[index] = makeEntry(tween)
            }
        } else {
            self.transactions.append(makeEntry(tween))
        }
    }

    func removeAnimation(label: AnyHashable) {
        // In-flight callbacks can remove their own entry. Marking it done keeps
        // indexes stable until the current controller tick finishes.
        guard let index = transactions.firstIndex(where: { $0.transaction.label == label }) else {
            return
        }
        transactions[index] = makeEntry(CancelledAnimation(label: label))
    }

    private struct CancelledAnimation: _AnimationTransaction {
        let state = _AnimationState.done
        let label: AnyHashable
        mutating func updateAnimation(_ deltaTime: TimeInterval) {}
    }

    private func makeEntry(_ transaction: any _AnimationTransaction) -> TransactionEntry {
        transactionRevision &+= 1
        return TransactionEntry(transaction: transaction, revision: transactionRevision)
    }

    func playAnimation() {
        self.isPlaying = true
    }

    func stopAnimation() {
        self.isPlaying = false
    }

    func update(_ deltaTime: TimeInterval) {
        guard self.isPlaying, !isUpdating else {
            return
        }

        isUpdating = true
        defer { isUpdating = false }

        // Layout callbacks may discover descendant animations that also need
        // this tick. Preserve that ordering without overwriting a retarget made
        // by the callback for the entry currently being sampled.
        var index = 0
        while index < transactions.count {
            guard isPlaying else { break }
            var entry = transactions[index]
            entry.transaction.updateAnimation(deltaTime)
            if transactions[index].revision == entry.revision {
                transactions[index] = entry
            }
            index += 1
        }

        transactions.removeAll(where: { $0.transaction.state == .done })

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
