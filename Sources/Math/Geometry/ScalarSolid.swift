import Foundation

/// A closed analytic operand; capsule halfHeight measures its centerline segment, excluding caps.
public enum ScalarSolidPrimitive: Codable, Equatable, Sendable {
    case sphere(radius: Float)
    case box(halfExtents: Vector3)
    case capsule(radius: Float, halfHeight: Float)
}

public enum ScalarSolidError: LocalizedError, Equatable, Sendable {
    case invalidPrimitive
    case invalidTransform
    case invalidPoint
    case unrepresentableResult
    case invalidDensity

    public var errorDescription: String? {
        switch self {
        case .invalidPrimitive: "Solid dimensions must be finite and positive, with a nonnegative capsule centerline"
        case .invalidTransform: "Solid placement requires a finite affine transform invertible at supported precision"
        case .invalidPoint: "Solid sample coordinates must be finite"
        case .unrepresentableResult: "Solid bounds or sample values exceed the supported numeric range"
        case .invalidDensity: "Boolean scalar operands must be finite"
        }
    }
}

/// An immutable negative-inside analytic field with full affine placement.
/// Nonuniform scale and shear preserve the zero set; values are not exact world distances.
public struct ScalarSolid: Sendable {
    public let primitive: ScalarSolidPrimitive
    public let transform: Transform3D
    /// Conservative bounds, including Float coordinate-rounding allowance.
    public let bounds: AABB
    private let frame: ScalarAffineFrame

    /// Validates finite affine placement and inverse precision without assuming operand dimensions.
    public static func validateTransform(_ transform: Transform3D) throws {
        _ = try ScalarAffineFrame(transform)
    }

    public init(primitive: ScalarSolidPrimitive, transform: Transform3D = .identity) throws {
        let extents = try Self.extents(primitive)
        let frame = try ScalarAffineFrame(transform)
        let bounds = try Self.bounds(extents: extents, transform: transform)
        self.primitive = primitive; self.transform = transform; self.frame = frame; self.bounds = bounds
    }

    /// Evaluates the placed field without generating geometry or allocating sample buffers.
    public func value(at point: Vector3) throws -> Float {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite else { throw ScalarSolidError.invalidPoint }
        let delta = SIMD3(Double(point.x) - Double(transform.w.x), Double(point.y) - Double(transform.w.y), Double(point.z) - Double(transform.w.z))
        let local = frame.local(delta)
        guard local.x.isFinite, local.y.isFinite, local.z.isFinite else { throw ScalarSolidError.unrepresentableResult }
        let distance: Double
        switch primitive {
        case let .sphere(radius): distance = scalarSolidLength(local) - Double(radius)
        case let .box(extents):
            let q = SIMD3(abs(local.x) - Double(extents.x), abs(local.y) - Double(extents.y), abs(local.z) - Double(extents.z))
            distance = scalarSolidLength(SIMD3(max(q.x, 0), max(q.y, 0), max(q.z, 0))) + min(max(q.x, max(q.y, q.z)), 0)
        case let .capsule(radius, halfHeight):
            distance = scalarSolidLength(SIMD3(local.x, max(abs(local.y) - Double(halfHeight), 0), local.z)) - Double(radius)
        }
        let result = Float(distance * frame.scale)
        guard result.isFinite else { throw ScalarSolidError.unrepresentableResult }
        return result
    }

    private static func extents(_ primitive: ScalarSolidPrimitive) throws -> SIMD3<Double> {
        switch primitive {
        case let .sphere(radius):
            guard radius.isFinite, radius > 0 else { throw ScalarSolidError.invalidPrimitive }
            return SIMD3(repeating: Double(radius))
        case let .box(extents):
            guard extents.x.isFinite, extents.y.isFinite, extents.z.isFinite, extents.x > 0, extents.y > 0, extents.z > 0 else {
                throw ScalarSolidError.invalidPrimitive
            }
            return SIMD3(Double(extents.x), Double(extents.y), Double(extents.z))
        case let .capsule(radius, halfHeight):
            guard radius.isFinite, radius > 0, halfHeight.isFinite, halfHeight >= 0 else { throw ScalarSolidError.invalidPrimitive }
            return SIMD3(Double(radius), Double(radius) + Double(halfHeight), Double(radius))
        }
    }

    private static func bounds(extents: SIMD3<Double>, transform: Transform3D) throws -> AABB {
        var half = SIMD3<Float>(repeating: 0)
        for axis in 0..<3 {
            let extent = abs(Double(transform[0, axis])) * extents.x + abs(Double(transform[1, axis])) * extents.y + abs(Double(transform[2, axis])) * extents.z
            let rounded = Float(extent)
            guard rounded.isFinite else { throw ScalarSolidError.unrepresentableResult }
            // Cover both the box arithmetic and a Float forward transform of a surface sample.
            let padded = extent + Double(transform[3, axis].ulp) + 4 * Double(rounded.ulp)
            var value = Float(padded)
            if Double(value) < padded { value = value.nextUp }
            guard value.isFinite else { throw ScalarSolidError.unrepresentableResult }
            half[axis] = value
        }
        let box = AABB(center: transform.origin, halfExtents: [half.x, half.y, half.z])
        let low = box.min, high = box.max
        guard low.x.isFinite, low.y.isFinite, low.z.isFinite, high.x.isFinite, high.y.isFinite, high.z.isFinite else {
            throw ScalarSolidError.unrepresentableResult
        }
        return box
    }
}

/// Double affine inversion keeps valid tiny scales distinct from singular placements.
struct ScalarAffineFrame: Sendable {
    private let x: SIMD3<Double>
    private let y: SIMD3<Double>
    private let z: SIMD3<Double>
    let scale: Double

    init(_ transform: Transform3D) throws {
        for column in 0..<4 {
            for row in 0..<4 where !transform[column, row].isFinite { throw ScalarSolidError.invalidTransform }
        }
        guard transform.x.w == 0, transform.y.w == 0, transform.z.w == 0, transform.w.w == 1 else { throw ScalarSolidError.invalidTransform }
        let a = Double(transform.x.x), b = Double(transform.y.x), c = Double(transform.z.x)
        let d = Double(transform.x.y), e = Double(transform.y.y), f = Double(transform.z.y)
        let g = Double(transform.x.z), h = Double(transform.y.z), i = Double(transform.z.z)
        let determinant = a * (e * i - f * h) - b * (d * i - f * g) + c * (d * h - e * g)
        guard determinant.isFinite, determinant != 0 else { throw ScalarSolidError.invalidTransform }
        let x = SIMD3(e * i - f * h, c * h - b * i, b * f - c * e) / determinant
        let y = SIMD3(f * g - d * i, a * i - c * g, c * d - a * f) / determinant
        let z = SIMD3(d * h - e * g, b * g - a * h, a * e - b * d) / determinant
        for column in 0..<3 {
            let inverse = SIMD3(x[column], y[column], z[column])
            let residual = SIMD3(scalarSolidDot(SIMD3(a, b, c), inverse), scalarSolidDot(SIMD3(d, e, f), inverse), scalarSolidDot(SIMD3(g, h, i), inverse))
            for row in 0..<3 {
                let expected: Double = row == column ? 1 : 0
                guard residual[row].isFinite, abs(residual[row] - expected) <= 1e-8 else { throw ScalarSolidError.invalidTransform }
            }
        }
        let scale = min(scalarSolidLength(SIMD3(a, d, g)), min(scalarSolidLength(SIMD3(b, e, h)), scalarSolidLength(SIMD3(c, f, i))))
        guard scale.isFinite, scale > 0 else { throw ScalarSolidError.invalidTransform }
        self.x = x; self.y = y; self.z = z; self.scale = scale
    }

    func local(_ delta: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(scalarSolidDot(x, delta), scalarSolidDot(y, delta), scalarSolidDot(z, delta))
    }
}

private func scalarSolidDot(_ lhs: SIMD3<Double>, _ rhs: SIMD3<Double>) -> Double {
    lhs.x * rhs.x + lhs.y * rhs.y + lhs.z * rhs.z
}

private func scalarSolidLength(_ value: SIMD3<Double>) -> Double {
    let maximum = max(abs(value.x), max(abs(value.y), abs(value.z)))
    guard maximum > 0 else {
        return 0
    }
    let unit = value / maximum
    return scalarSolidDot(unit, unit).squareRoot() * maximum
}
