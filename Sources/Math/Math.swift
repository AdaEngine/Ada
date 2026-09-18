//
//  Math.swift
//  AdaEngine
//
//  Created by v.prusakov on 11/12/21.
//

#if canImport(Glibc)
    import Glibc
#endif

#if canImport(Darwin)
    import Darwin.C
#endif

#if canImport(WinSDK)
    import WinSDK
#endif

#if canImport(WASILibc)
    import WASILibc
#endif

// swiftlint:disable identifier_name

// TODO: Suppors Android/Web?

@inlinable
@inline(__always)
public func tanf(_ float: Float) -> Float {
    #if os(Linux)
        return Glibc.tanf(float)
    #elseif os(Windows)
        return WinSDK.tanf(float)
    #elseif os(WASI)
        return WASILibc.tanf(float)
    #else
        return Darwin.tanf(float)
    #endif
}

@inlinable
@inline(__always)
public func atan2(_ lhs: Double, _ rhs: Double) -> Double {
    #if os(Linux)
        return Glibc.atan2(lhs, rhs)
    #elseif os(Windows)
        return WinSDK.atan2(lhs, rhs)
    #elseif os(WASI)
        return WASILibc.atan2(lhs, rhs)
    #else
        return Darwin.atan2(lhs, rhs)
    #endif
}

@inlinable
@inline(__always)
public func atan2(_ lhs: Float, _ rhs: Float) -> Float {
    #if os(Linux)
        return Glibc.atan2(lhs, rhs)
    #elseif os(Windows)
        return WinSDK.atan2f(lhs, rhs)
    #elseif os(WASI)
        return WASILibc.atan2f(lhs, rhs)
    #else
        return Darwin.atan2(lhs, rhs)
    #endif
}

@inlinable
@inline(__always)
public func sqrt(_ value: Float) -> Float {
    #if os(Linux)
        return Glibc.sqrtf(value)
    #elseif os(Windows)
        return WinSDK.sqrtf(value)
    #elseif os(WASI)
        return WASILibc.sqrtf(value)
    #else
        return Darwin.sqrtf(value)
    #endif
}

@inlinable
@inline(__always)
public func sqrt(_ value: Double) -> Double {
    #if os(Linux)
        return Glibc.sqrt(value)
    #elseif os(Windows)
        return WinSDK.sqrt(value)
    #elseif os(WASI)
        return WASILibc.sqrt(value)
    #else
        return Darwin.sqrt(value)
    #endif
}

@inlinable
@inline(__always)
public func clamp<T: Comparable>(_ value: T, _ min: T, _ max: T) -> T {
    return value < min ? min : (value > max ? max : value)
}

@inlinable
@inline(__always)
public func cross(_ lhs: Vector3, _ rhs: Vector3) -> Vector3 {
    var x1 = lhs.y * rhs.z
    x1 = x1 - rhs.y * lhs.z
    var y1 = lhs.z * rhs.x
    y1 = y1 - rhs.z * lhs.x
    var z1 = lhs.x * rhs.y
    z1 = z1 - rhs.x * lhs.y
    return Vector3(x1, y1, z1)
}

@inlinable
@inline(__always)
public func round<T: FloatingPoint>(_ value: T) -> T {
    #if os(Linux)
        return Glibc.round(value)
    #elseif os(Windows)
        if let value = value as? Float {
            return WinSDK.roundf(value) as! T
        } else if let value = value as? Double {
            return WinSDK.round(value) as! T
        }
        fatalError("Unsupported type")
    #elseif os(WASI)
        if let value = value as? Float {
            return WASILibc.roundf(value) as! T
        } else if let value = value as? Double {
            return WASILibc.round(value) as! T
        }
        fatalError("Unsupported type")
    #else
        return Darwin.round(value)
    #endif
}

@inlinable
@inline(__always)
public func sin(_ value: Double) -> Double {
    #if os(Linux)
        return Glibc.sin(value)
    #elseif os(Windows)
        return WinSDK.sin(value)
    #elseif os(WASI)
        return WASILibc.sin(value)
    #else
        return Darwin.sin(value)
    #endif
}

@inlinable
@inline(__always)
public func sin(_ value: Float) -> Float {
    #if os(Linux)
        return Glibc.sinf(value)
    #elseif os(Windows)
        return WinSDK.sinf(value)
    #elseif os(WASI)
        return WASILibc.sinf(value)
    #else
        return Darwin.sinf(value)
    #endif
}

@inlinable
@inline(__always)
public func cos(_ value: Double) -> Double {
    #if os(Linux)
        return Glibc.cos(value)
    #elseif os(Windows)
        return WinSDK.cos(value)
    #elseif os(WASI)
        return WASILibc.cos(value)
    #else
        return Darwin.cos(value)
    #endif
}

@inlinable
@inline(__always)
public func cos(_ value: Float) -> Float {
    #if os(Linux)
        return Glibc.cosf(value)
    #elseif os(Windows)
        return WinSDK.cosf(value)
    #elseif os(WASI)
        return WASILibc.cosf(value)
    #else
        return Darwin.cosf(value)
    #endif
}

@inlinable
@inline(__always)
public func acos(_ value: Float) -> Float {
    #if os(Linux)
        return Glibc.acos(value)
    #elseif os(Windows)
        return WinSDK.acosf(value)
    #elseif os(WASI)
        return WASILibc.acosf(value)
    #else
        return Darwin.acos(value)
    #endif
}

@inlinable
@inline(__always)
public func acos(_ value: Double) -> Double {
    #if os(Linux)
        return Glibc.acos(value)
    #elseif os(Windows)
        return WinSDK.acos(value)
    #elseif os(WASI)
        return WASILibc.acos(value)
    #else
        return Darwin.acos(value)
    #endif
}

@inlinable
@inline(__always)
public func sign(_ x: Float) -> Float {
    return x == 0 ? 0 : x < 0 ? -1 : 1
}

/// Linearly interpolates between two points.
public func lerpf(_ lhs: Float, _ rhs: Float, _ t: Float) -> Float {
    return lhs + (rhs - lhs) * t
}

/// Linearly interpolates between two points.
public func lerp<T: FloatingPoint>(_ lhs: T, _ rhs: T, _ t: T) -> T {
    return lhs + (rhs - lhs) * t
}

/// Linearly interpolates between two points.
public func lerp(_ lhs: Double, _ rhs: Double, _ t: Double) -> Double {
    return lhs + (rhs - lhs) * t
}

// swiftlint:enable identifier_name
