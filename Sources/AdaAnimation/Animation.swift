//
//  Animation.swift
//  AdaAnimation
//

import AdaUtils

/// A context for an animation (tween curves). UI layers may ignore this; keyframe sampling does not use it.
public struct AnimationContext<V: VectorArithmetic>: Sendable {
    public init() {}
}

/// A protocol that defines the behavior of a custom animation.
public protocol CustomAnimation: Hashable {
    /// The finite duration of this animation, if it has one.
    var finiteDuration: TimeInterval? { get }

    /// Calculates the value of the animation at the specified time.
    func animate<V: VectorArithmetic>(_ value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V?

    /// The default implementation of this method returns nil.
    func velocity<V: VectorArithmetic>(_ value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V?

    /// Determines whether an instance of the animation can merge with other instance of the same type.
    func shouldMerge<V>(
        previous: Animation,
        value: V,
        time: TimeInterval,
        context: inout AnimationContext<V>
    ) -> Bool where V: VectorArithmetic
}

extension CustomAnimation {
    public var finiteDuration: TimeInterval? {
        nil
    }

    public func velocity<V>(_: V, time _: TimeInterval, context _: inout AnimationContext<V>) -> V? where V: VectorArithmetic {
        return nil
    }

    public func shouldMerge<V>(previous _: Animation, value _: V, time _: TimeInterval, context _: inout AnimationContext<V>) -> Bool where V: VectorArithmetic {
        return false
    }
}

/// A linear animation.
struct LinearAnimation: CustomAnimation {
    let duration: TimeInterval

    var finiteDuration: TimeInterval? {
        duration
    }

    func animate<V: VectorArithmetic>(_ value: V, time: TimeInterval, context _: inout AnimationContext<V>) -> V? {
        guard time < duration else {
            return nil
        }

        return value.scaled(by: Double(time / duration))
    }

    func velocity<V>(_ value: V, time _: TimeInterval, context _: inout AnimationContext<V>) -> V? where V: VectorArithmetic {
        value.scaled(by: Double(1.0 / duration))
    }
}

/// A type that represents an animation.
public struct Animation: Equatable, @unchecked Sendable {
    /// The base animation.
    public let base: any CustomAnimation

    /// Initialize a new animation.
    ///
    /// - Parameter base: The base animation.
    public init<T: CustomAnimation>(_ base: T) {
        self.base = base
    }

    /// Check if two animations are equal.
    public static func == (lhs: Self, rhs: Self) -> Bool {
        return lhs.base.hashValue == rhs.base.hashValue
    }
}

/// A default animation.
extension Animation {
    /// The default animation.
    public static let `default`: Animation = .linear

    /// A linear animation.
    public static let linear: Animation = .linear(duration: 1)

    /// Create a linear animation.
    public static func linear(duration: TimeInterval) -> Animation {
        Animation(LinearAnimation(duration: duration))
    }

    /// Create a delay animation.
    public func delay(_ duration: TimeInterval) -> Animation {
        let delay = Animation(DelayAnimation(duration: duration))
        return Animation(CombineAnimation(left: delay, right: self))
    }

    /// Repeats this animation indefinitely.
    ///
    /// When `autoreverses` is true, every odd cycle plays the finite base animation backward.
    public func repeatForever(autoreverses: Bool = true) -> Animation {
        Animation(RepeatForeverAnimation(base: self, autoreverses: autoreverses))
    }
}

/// A delay animation.
struct DelayAnimation: CustomAnimation {
    let duration: TimeInterval

    var finiteDuration: TimeInterval? {
        duration
    }

    func animate<V: VectorArithmetic>(_ value: V, time: TimeInterval, context _: inout AnimationContext<V>) -> V? {
        guard time < duration else {
            return nil
        }

        return value.scaled(by: Double(time / duration))
    }
}

/// A combine animation.
struct CombineAnimation: CustomAnimation {
    let left: Animation
    let right: Animation

    var finiteDuration: TimeInterval? {
        switch (left.base.finiteDuration, right.base.finiteDuration) {
        case let (.some(leftDuration), .some(rightDuration)):
            return max(leftDuration, rightDuration)
        default:
            return nil
        }
    }

    func animate<V>(_ value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? where V: VectorArithmetic {
        if let value = left.base.animate(value, time: time, context: &context) {
            return value
        }

        return right.base.animate(value, time: time, context: &context)
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(left.base)
        hasher.combine(right.base)
    }
}

/// An animation that loops a finite base animation forever.
struct RepeatForeverAnimation: CustomAnimation {
    let base: Animation
    let autoreverses: Bool

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.base == rhs.base && lhs.autoreverses == rhs.autoreverses
    }

    func animate<V>(_ value: V, time: TimeInterval, context: inout AnimationContext<V>) -> V? where V: VectorArithmetic {
        guard let duration = base.base.finiteDuration, duration > 0 else {
            return base.base.animate(value, time: time, context: &context)
        }

        let cycleDuration = autoreverses ? duration * 2 : duration
        var cycleTime = time.truncatingRemainder(dividingBy: cycleDuration)
        if cycleTime < 0 {
            cycleTime += cycleDuration
        }

        let localTime: TimeInterval
        if autoreverses && cycleTime >= duration {
            localTime = cycleDuration - cycleTime
        } else {
            localTime = cycleTime
        }

        return base.base.animate(value, time: localTime, context: &context) ?? value
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(base.base)
        hasher.combine(autoreverses)
    }
}
