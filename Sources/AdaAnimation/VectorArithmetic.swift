//
//  VectorArithmetic.swift
//  AdaAnimation
//

import Math

/// A type that can serve as the animatable data of an animatable type.
///
/// VectorArithmetic extends AdditiveArithmetic with scalar multiplication and a way to query a
/// value's vector magnitude. Use this type as the animatableData associated type of an Animatable type.
public protocol VectorArithmetic: AdditiveArithmetic {
    /// The magnitude squared of the vector.
    var magnitudeSquared: Double { get }

    /// Scale the vector by a given value.
    ///
    /// - Parameter rhs: The value to scale the vector by.
    mutating func scale(by rhs: Double)
}

extension VectorArithmetic {
    /// Returns a value with each component of this value multiplied by the
    /// given value.
    public func scaled(by rhs: Double) -> Self {
        var value = self
        value.scale(by: rhs)
        return value
    }

    /// Interpolates this value with `other` by the specified `amount`.
    ///
    /// This is equivalent to `self = self + (other - self) * amount`.
    public mutating func interpolate(towards other: Self, amount: Double) {
        self = self.interpolated(towards: other, amount: amount)
    }

    /// Returns this value interpolated with `other` by the specified `amount`.
    ///
    /// This result is equivalent to `self + (other - self) * amount`.
    public func interpolated(towards other: Self, amount: Double) -> Self {
        return self + (other - self).scaled(by: amount)
    }
}

extension Double: VectorArithmetic {
    public var magnitudeSquared: Double {
        self * self
    }

    public mutating func scale(by rhs: Double) {
        self *= rhs
    }
}

extension Float: VectorArithmetic {
    public var magnitudeSquared: Double {
        Double(self * self)
    }

    public mutating func scale(by rhs: Double) {
        self *= Float(rhs)
    }
}

extension Math.Vector3: VectorArithmetic {
    public var magnitudeSquared: Double {
        Double(self.dot(self))
    }

    public mutating func scale(by rhs: Double) {
        self.x.scale(by: rhs)
        self.y.scale(by: rhs)
        self.z.scale(by: rhs)
    }
}

extension Math.Vector2: VectorArithmetic {
    public var magnitudeSquared: Double {
        Double(self.dot(self))
    }

    public mutating func scale(by rhs: Double) {
        self.x.scale(by: rhs)
        self.y.scale(by: rhs)
    }
}

extension Math.Vector4: VectorArithmetic {
    public var magnitudeSquared: Double {
        Double(self.dot(self))
    }

    public mutating func scale(by rhs: Double) {
        self.x.scale(by: rhs)
        self.y.scale(by: rhs)
        self.z.scale(by: rhs)
        self.w.scale(by: rhs)
    }
}

extension Rect: Animatable {
    public var animatableData: AnimatablePair<Vector2, Vector2> {
        get {
            return AnimatablePair(
                self.origin,
                self.size.asVector2
            )
        }

        set {
            self.origin = newValue.first
            self.size = Size(width: newValue.second.x, height: newValue.second.y)
        }
    }
}
