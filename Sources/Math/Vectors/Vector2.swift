//
//  Vector2.swift
//  AdaEngine
//
//  Created by v.prusakov on 8/12/21.
//

// TODO: (Vlad) Create object aka CGFloat for float or doubles
// TODO: (Vlad) when move to new vector object, we should use same object size
// TODO: In swift 5.0 now SIMD is part of stdlib, should we support it instead of vector types..

/// A 2-dimensional vector used for 2D math using floating point coordinates.
@frozen
public struct Vector2: Hashable, Equatable, Codable, Sendable {
    public var x: Float
    public var y: Float

    @inlinable
    @inline(__always)
    public init(x: Float, y: Float) {
        self.x = x
        self.y = y
    }

    @inlinable
    @inline(__always)
    public init() {
        self.x = 0
        self.y = 0
    }
}

extension Vector2 {
    @inlinable
    @inline(__always)
    public init(_ scalar: Float) {
        self.x = scalar
        self.y = scalar
    }

    @inlinable
    @inline(__always)
    public init(_ x: Float, _ y: Float) {
        self.x = x
        self.y = y
    }
}

extension Vector2: ExpressibleByFloatLiteral {
    public typealias FloatLiteralType = Float

    public init(floatLiteral value: Float) {
        self.init(value)
    }
}

extension Vector2: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Float...) {
        assert(elements.count == 2)
        self.x = elements[0]
        self.y = elements[1]
    }
}

extension Vector2 {
    @inlinable
    public subscript(_ index: Int) -> Float {
        get {
            switch index {
            case 0:
                return x
            case 1:
                return y
            default:
                fatalError("Index out of range.")
            }
        }

        set {
            switch index {
            case 0:
                self.x = newValue
            case 1:
                self.y = newValue
            default: fatalError("Index out of range.")
            }
        }
    }
}

extension Vector2 {
    @inlinable
    @inline(__always)
    public var squaredLength: Float {
        return x * x + y * y
    }

    @inlinable
    @inline(__always)
    public var normalized: Vector2 {
        let length = sqrt(self.squaredLength)
        if length < Float.ulpOfOne {
            return .zero
        }

        let invLength = 1.0 / length
        return Vector2(invLength * x, invLength * y)
    }

    @inlinable
    @inline(__always)
    public var isNaN: Bool {
        return self.x.isNaN || self.y.isNaN
    }

    @inlinable
    @inline(__always)
    public func dot(_ vector: borrowing Vector2) -> Float {
        return x * vector.x + y * vector.y
    }

    @inlinable
    @inline(__always)
    public func clamped(to rect: borrowing Rect) -> Point {
        let x = clamp(self.x, rect.minX, rect.maxX)
        let y = clamp(self.y, rect.minY, rect.maxY)
        return Point(x: x, y: y)
    }
}

extension Vector2: Comparable {
    public static func < (lhs: Vector2, rhs: Vector2) -> Bool {
        lhs.x < rhs.x && lhs.y < rhs.y
    }
}

// MARK: Math Operations

extension Vector2 {
    // MARK: Scalar

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func * (lhs: borrowing Vector2, rhs: Float) -> Vector2 {
        return Vector2(lhs.x * rhs, lhs.y * rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func + (lhs: borrowing Vector2, rhs: Float) -> Vector2 {
        return Vector2(lhs.x + rhs, lhs.y + rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func - (lhs: borrowing Vector2, rhs: Float) -> Vector2 {
        return Vector2(lhs.x - rhs, lhs.y - rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func / (lhs: borrowing Vector2, rhs: Float) -> Vector2 {
        return Vector2(lhs.x / rhs, lhs.y / rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func * (lhs: Float, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs * rhs.x, lhs * rhs.y)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func + (lhs: Float, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs + rhs.x, lhs + rhs.y)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func - (lhs: Float, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs - rhs.x, lhs - rhs.y)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func / (lhs: Float, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs / rhs.x, lhs / rhs.y)
    }

    @inlinable
    @inline(__always)
    public static func *= (lhs: inout Vector2, rhs: Float) {
        lhs = lhs * rhs
    }

    @inlinable
    @inline(__always)
    public static func -= (lhs: inout Vector2, rhs: Float) {
        lhs = lhs - rhs
    }

    @inlinable
    @inline(__always)
    public static func /= (lhs: inout Vector2, rhs: Float) {
        lhs = lhs / rhs
    }

    @inlinable
    @inline(__always)
    public static func += (lhs: inout Vector2, rhs: Float) {
        lhs = lhs + rhs
    }

    // MARK: Vector

    @inlinable
    @inline(__always)
    public static func + (lhs: borrowing Vector2, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(x: lhs.x + rhs.x, y: lhs.y + rhs.y)
    }

    @inlinable
    @inline(__always)
    public static func * (lhs: borrowing Vector2, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs.x * rhs.x, lhs.y * rhs.y)
    }

    @inlinable
    @inline(__always)
    public static func - (lhs: borrowing Vector2, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    @inlinable
    @inline(__always)
    public static prefix func - (lhs: borrowing Vector2) -> Vector2 {
        return Vector2(-lhs.x, -lhs.y)
    }

    @inlinable
    @inline(__always)
    public static func / (lhs: borrowing Vector2, rhs: borrowing Vector2) -> Vector2 {
        return Vector2(lhs.x / rhs.x, lhs.y / rhs.y)
    }

    @inlinable
    @inline(__always)
    public static func *= (lhs: inout Vector2, rhs: borrowing Vector2) {
        lhs = lhs * rhs
    }

    @inlinable
    @inline(__always)
    public static func += (lhs: inout Vector2, rhs: borrowing Vector2) {
        lhs = lhs + rhs
    }

    @inlinable
    @inline(__always)
    public static func -= (lhs: inout Vector2, rhs: borrowing Vector2) {
        lhs = lhs - rhs
    }

    @inlinable
    @inline(__always)
    public static func /= (lhs: inout Vector2, rhs: borrowing Vector2) {
        lhs = lhs / rhs
    }
}

extension Vector2 {
    public var description: String {
        return String(describing: type(of: self)) + "(\(x), \(y))"
    }
}

extension Vector2 {
    @inline(__always)
    public static let zero: Vector2 = Vector2(0)

    @inline(__always)
    public static let one: Vector2 = Vector2(1)
}

public typealias Point = Vector2

extension Point {
    public func applying(_ affineTransform: borrowing Transform2D) -> Point {
        return Point(
            x: self.x * affineTransform[0, 0] + y * affineTransform[1, 0] + affineTransform.position.x,
            y: self.x * affineTransform[0, 1] + y * affineTransform[1, 1] + affineTransform.position.y
        )
    }
}

#if canImport(CoreGraphics)
    import CoreGraphics
    extension Point {
        @inline(__always)
        public var toCGPoint: CGPoint {
            return CGPoint(x: Double(self.x), y: Double(self.y))
        }
    }
#endif

/// Returns a vector containing the minimum values for each element of `lhs` and `rhs`.
///
/// In other words this computes `[min(lhs.x, rhs.x), min(lhs.y, rhs.y), ..]`.
@inlinable
@inline(__always)
public func min(_ lhs: borrowing Vector2, _ rhs: borrowing Vector2) -> Vector2 {
    Vector2(
        min(lhs.x, rhs.x),
        min(lhs.y, rhs.y)
    )
}

/// Returns a vector containing the maximum values for each element of `lhs` and `rhs`.
///
/// In other words this computes `[max(lhs.x, rhs.x), max(lhs.y, rhs.y), ..]`.
@inlinable
@inline(__always)
public func max(_ lhs: borrowing Vector2, _ rhs: borrowing Vector2) -> Vector2 {
    Vector2(
        max(lhs.x, rhs.x),
        max(lhs.y, rhs.y)
    )
}

/// Linearly interpolates between two points.
public func lerp(_ lhs: borrowing Vector2, _ rhs: borrowing Vector2, _ t: Float) -> Vector2 {
    return lhs + (rhs - lhs) * t
}
