//
//  Vector4.swift
//  AdaEngine
//
//  Created by v.prusakov on 6/22/22.
//

/// A 4-dimensional vector used for 4D math using floating point coordinates.
@frozen
public struct Vector4: Hashable, Equatable, Codable, Sendable {
    public var x: Float
    public var y: Float
    public var z: Float
    public var w: Float

    @inlinable
    @inline(__always)
    public init(x: Float, y: Float, z: Float, w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    @inlinable
    @inline(__always)
    public init() {
        self.x = 0
        self.y = 0
        self.z = 0
        self.w = 0
    }
}

extension Vector4 {
    @inlinable
    @inline(__always)
    public init(_ scalar: Float) {
        self.x = scalar
        self.y = scalar
        self.z = scalar
        self.w = scalar
    }

    @inlinable
    @inline(__always)
    public init(_ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    @inlinable
    @inline(__always)
    public init(_ xyz: Float, _ w: Float) {
        self.x = xyz
        self.y = xyz
        self.z = xyz
        self.w = w
    }

    @inlinable
    @inline(__always)
    public init(_ vector3: Vector3, _ w: Float) {
        self.x = vector3.x
        self.y = vector3.y
        self.z = vector3.z
        self.w = w
    }
}

extension Vector4: ExpressibleByFloatLiteral {
    public typealias FloatLiteralType = Float

    public init(floatLiteral value: Float) {
        self.init(value)
    }
}

extension Vector4: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: Float...) {
        assert(elements.count == 4)
        self.x = elements[0]
        self.y = elements[1]
        self.z = elements[2]
        self.w = elements[3]
    }
}

extension Vector4 {
    public subscript(_ index: Int) -> Float {
        get {
            switch index {
            case 0:
                return x
            case 1:
                return y
            case 2:
                return z
            case 3:
                return w
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
            case 2:
                self.z = newValue
            case 3:
                self.w = newValue
            default: fatalError("Index out of range.")
            }
        }
    }
}

extension Vector4 {
    public var description: String {
        return String(describing: type(of: self)) + "(\(x), \(y), \(z), \(w))"
    }
}

extension Vector4: Comparable {
    public static func < (lhs: Vector4, rhs: Vector4) -> Bool {
        lhs.x < rhs.x && lhs.y < rhs.y && lhs.z < rhs.z && lhs.w < rhs.w
    }
}

// MARK: Math Operations

extension Vector4 {
    // MARK: Scalar

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func * (lhs: borrowing Vector4, rhs: Float) -> Vector4 {
        return Vector4(lhs.x * rhs, lhs.y * rhs, lhs.z * rhs, lhs.w * rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func + (lhs: borrowing Vector4, rhs: Float) -> Vector4 {
        return Vector4(lhs.x + rhs, lhs.y + rhs, lhs.z + rhs, lhs.w + rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func - (lhs: borrowing Vector4, rhs: Float) -> Vector4 {
        return Vector4(lhs.x - rhs, lhs.y - rhs, lhs.z - rhs, lhs.w - rhs)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func * (lhs: Float, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs * rhs.x, lhs * rhs.y, lhs * rhs.z, lhs * rhs.w)
    }

    @inlinable
    @inline(__always)
    public static func + (lhs: Float, rhs: Vector4) -> Vector4 {
        return Vector4(lhs + rhs.x, lhs + rhs.y, lhs + rhs.z, lhs + rhs.w)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func - (lhs: Float, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs - rhs.x, lhs - rhs.y, lhs - rhs.z, lhs - rhs.w)
    }

    @inlinable
    @inline(__always)
    public static prefix func - (lhs: borrowing Vector4) -> Vector4 {
        return Vector4(-lhs.x, -lhs.y, -lhs.z, -lhs.w)
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func / (lhs: Float, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs / rhs.x, lhs / rhs.y, lhs / rhs.z, lhs / rhs.w)
    }

    @inlinable
    @inline(__always)
    public static func *= (lhs: inout Vector4, rhs: Float) {
        lhs = lhs * rhs
    }

    @inlinable
    @inline(__always)
    public static func -= (lhs: inout Vector4, rhs: Float) {
        lhs = lhs - rhs
    }

    @inlinable
    @inline(__always)
    public static func /= (lhs: inout Vector4, rhs: Float) {
        lhs = lhs / rhs
    }

    @inlinable
    @inline(__always)
    public static func += (lhs: inout Vector4, rhs: Float) {
        lhs = lhs + rhs
    }

    @inlinable
    @inline(__always)
    @_disfavoredOverload
    public static func / (lhs: borrowing Vector4, rhs: Float) -> Vector4 {
        return Vector4(lhs.x / rhs, lhs.y / rhs, lhs.z / rhs, lhs.w / rhs)
    }

    @inlinable
    @inline(__always)
    public static func - (lhs: borrowing Vector4, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs.x - rhs.x, lhs.y - rhs.y, lhs.z - rhs.z, lhs.w - rhs.w)
    }

    @inlinable
    @inline(__always)
    public static func + (lhs: borrowing Vector4, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs.x + rhs.x, lhs.y + rhs.y, lhs.z + rhs.z, lhs.w + rhs.w)
    }

    @inlinable
    @inline(__always)
    public static func * (lhs: borrowing Vector4, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs.x * rhs.x, lhs.y * rhs.y, lhs.z * rhs.z, lhs.w * rhs.w)
    }

    // MARK: Vector

    @inlinable
    @inline(__always)
    public static func / (lhs: borrowing Vector4, rhs: borrowing Vector4) -> Vector4 {
        return Vector4(lhs.x / rhs.x, lhs.y / rhs.y, lhs.z / rhs.z, lhs.w / rhs.w)
    }

    @inlinable
    @inline(__always)
    public static func *= (lhs: inout Vector4, rhs: borrowing Vector4) {
        lhs = lhs * rhs
    }

    @inlinable
    @inline(__always)
    public static func += (lhs: inout Vector4, rhs: borrowing Vector4) {
        lhs = lhs + rhs
    }

    @inlinable
    @inline(__always)
    public static func -= (lhs: inout Vector4, rhs: borrowing Vector4) {
        lhs = lhs - rhs
    }

    @inlinable
    @inline(__always)
    public static func /= (lhs: inout Vector4, rhs: borrowing Vector4) {
        lhs = lhs / rhs
    }

    // MARK: Matrix

    @inlinable
    @inline(__always)
    public static func * (lhs: borrowing Transform3D, rhs: borrowing Vector4) -> Vector4 {
        var rv = lhs.x * rhs.x
        rv = rv + lhs.y * rhs.y
        rv = rv + lhs.z * rhs.z
        rv = rv + lhs.w * rhs.w
        return rv
    }

    @inlinable
    @inline(__always)
    public static func * (lhs: borrowing Vector4, rhs: borrowing Transform3D) -> Vector4 {
        var x = lhs.x * rhs.x.x
        x = x + lhs.y * rhs.x.y
        x = x + lhs.z * rhs.x.z
        x = x + lhs.w * rhs.x.w
        var y = lhs.x * rhs.y.x
        y = y + lhs.y * rhs.y.y
        y = y + lhs.z * rhs.y.z
        y = y + lhs.w * rhs.y.w
        var z = lhs.x * rhs.z.x
        z = z + lhs.y * rhs.z.y
        z = z + lhs.z * rhs.z.z
        z = z + lhs.w * rhs.z.w
        var w = lhs.x * rhs.w.x
        w = w + lhs.y * rhs.w.y
        w = w + lhs.z * rhs.w.z
        w = w + lhs.w * rhs.w.w
        return Vector4(x, y, z, w)
    }
}

extension Vector4 {
    @inline(__always)
    public static let zero: Vector4 = Vector4(0)

    @inline(__always)
    public static let one: Vector4 = Vector4(1)
}

extension Vector4 {
    @inlinable
    @inline(__always)
    public var squaredLength: Float {
        return x * x + y * y + z * z + w * w
    }

    @inlinable
    @inline(__always)
    public var normalized: Vector4 {
        let length = self.squaredLength
        return self / sqrt(length)
    }

    @inlinable
    @inline(__always)
    public var isNaN: Bool {
        return self.x.isNaN || self.y.isNaN || self.z.isNaN || self.w.isNaN
    }

    @inlinable
    @inline(__always)
    public func dot(_ vector: borrowing Vector4) -> Float {
        return x * vector.x + y * vector.y + z * vector.z + w * vector.w
    }
}

extension Vector4 {
    public var xyz: Vector3 {
        get {
            return Vector3(self.x, self.y, self.z)
        }

        set {
            self.x = newValue.x
            self.y = newValue.y
            self.z = newValue.z
        }
    }
}

/// Returns a vector containing the minimum values for each element of `lhs` and `rhs`.
///
/// In other words this computes `[min(lhs.x, rhs.x), min(lhs.y, rhs.y), ..]`.
@inlinable
@inline(__always)
public func min(_ lhs: borrowing Vector4, _ rhs: borrowing Vector4) -> Vector4 {
    Vector4(
        min(lhs.x, rhs.x),
        min(lhs.y, rhs.y),
        min(lhs.z, rhs.z),
        min(lhs.w, rhs.w)
    )
}

/// Returns a vector containing the maximum values for each element of `lhs` and `rhs`.
///
/// In other words this computes `[max(lhs.x, rhs.x), max(lhs.y, rhs.y), ..]`.
@inlinable
@inline(__always)
public func max(_ lhs: borrowing Vector4, _ rhs: borrowing Vector4) -> Vector4 {
    Vector4(
        max(lhs.x, rhs.x),
        max(lhs.y, rhs.y),
        max(lhs.z, rhs.z),
        max(lhs.w, rhs.w)
    )
}

/// Linearly interpolates between two points.
public func lerp(_ lhs: borrowing Vector4, _ rhs: borrowing Vector4, _ t: Float) -> Vector4 {
    return lhs + (rhs - lhs) * t
}
