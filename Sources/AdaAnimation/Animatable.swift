//
//  Animatable.swift
//  AdaAnimation
//

import Math

/// A type that describes how to animate a property of a view.
@MainActor
public protocol Animatable {
    /// The type defining the data to animate.
    associatedtype AnimatableData: VectorArithmetic

    /// The data to animate.
    var animatableData: AnimatableData { get set }
}

extension Animatable where Self: VectorArithmetic {
    /// The data to animate.
    public var animatableData: Self {
        get { self }
        set { self = newValue }
    }
}

extension Animatable where Self.AnimatableData == EmptyAnimatableData {
    /// The data to animate.
    public var animatableData: EmptyAnimatableData {
        get { EmptyAnimatableData() }
        // swiftlint:disable:next unused_setter_value
        set {}
    }
}

/// An empty type for animatable data.
public struct EmptyAnimatableData: VectorArithmetic, Sendable {
    /// Subtract two empty animatable data.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side of the subtraction.
    ///   - rhs: The right-hand side of the subtraction.
    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(value: lhs.value - rhs.value)
    }

    /// Add two empty animatable data.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side of the addition.
    ///   - rhs: The right-hand side of the addition.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(value: lhs.value + rhs.value)
    }

    /// The zero value of the empty animatable data.
    public static let zero: EmptyAnimatableData = Self(value: 0)

    /// The value of the empty animatable data.
    var value: Double

    init(value: Double) {
        self.value = value
    }

    /// Initialize a new empty animatable data.
    public init() {
        self.value = 0
    }

    /// Scale the empty animatable data by a given value.
    ///
    /// - Parameter rhs: The value to scale the empty animatable data by.
    public mutating func scale(by rhs: Double) {
        value = value * rhs
    }

    /// The magnitude squared of the empty animatable data.
    public var magnitudeSquared: Double { return 0 }
}

/// A pair of animatable values, which is itself animatable.
public struct AnimatablePair<First: VectorArithmetic, Second: VectorArithmetic>: VectorArithmetic {
    /// The first value of the animatable pair.
    public var first: First

    /// The second value of the animatable pair.
    public var second: Second

    /// Creates an animated pair with the provided values.
    public init(_ first: First, _ second: Second) {
        self.first = first
        self.second = second
    }

    /// Scale the animatable pair by a given value.
    ///
    /// - Parameter rhs: The value to scale the animatable pair by.
    public mutating func scale(by rhs: Double) {
        self.first.scale(by: rhs)
        self.second.scale(by: rhs)
    }

    /// The magnitude squared of the animatable pair.
    public var magnitudeSquared: Double {
        self.first.magnitudeSquared * self.second.magnitudeSquared
    }

    /// Subtract two animatable pairs.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side of the subtraction.
    ///   - rhs: The right-hand side of the subtraction.
    public static func - (lhs: Self, rhs: Self) -> Self {
        Self(lhs.first - rhs.first, lhs.second - rhs.second)
    }

    /// Add two animatable pairs.
    ///
    /// - Parameters:
    ///   - lhs: The left-hand side of the addition.
    ///   - rhs: The right-hand side of the addition.
    public static func + (lhs: Self, rhs: Self) -> Self {
        Self(lhs.first + rhs.first, lhs.second + rhs.second)
    }

    /// The zero value of the animatable pair.
    public static var zero: AnimatablePair<First, Second> { return Self(First.zero, Second.zero) }
}
