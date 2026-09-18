//
//  Transform2D.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/20/21.
//

// swiftlint:disable identifier_name

@frozen
public struct Transform2D: Hashable, Sendable {
    public var x: Vector3
    public var y: Vector3
    public var z: Vector3

    @inline(__always)
    public init() {
        self.x = Vector3(1, 0, 0)
        self.y = Vector3(0, 1, 0)
        self.z = Vector3(0, 0, 1)
    }
}

extension Transform2D {
    @inline(__always)
    public init(translation: borrowing Vector2) {
        self.x = Vector3(1, 0, 0)
        self.y = Vector3(0, 1, 0)
        self.z = Vector3(translation.x, translation.y, 1)
    }

    @inline(__always)
    public init(scale: borrowing Vector2) {
        var matrix = Self.identity
        matrix[0, 0] = scale.x
        matrix[1, 1] = scale.y
        self = matrix
    }

    @inline(__always)
    public init(rotation: borrowing Angle) {
        var matrix = Self.identity
        matrix[0, 0] = cos(rotation.radians)
        matrix[0, 1] = sin(rotation.radians)
        matrix[1, 0] = -sin(rotation.radians)
        matrix[1, 1] = cos(rotation.radians)
        self = matrix
    }

    @inline(__always)
    public init(columns: borrowing [Vector3]) {
        precondition(columns.count == 3, "Inconsist columns count")
        self.x = columns[0]
        self.y = columns[1]
        self.z = columns[2]
    }

    @inline(__always)
    public init(diagonal: Float) {
        var matrix = Self.identity
        matrix[0, 0] = diagonal
        matrix[1, 1] = diagonal
        matrix[2, 2] = diagonal
        self = matrix
    }

    @inline(__always)
    public init(_ x: consuming Vector3, _ y: consuming Vector3, _ z: consuming Vector3) {
        self.x = x
        self.y = y
        self.z = z
    }
}

extension Transform2D: Codable {}

extension Transform2D: CustomDebugStringConvertible {
    public var debugDescription: String {
        return String(describing: type(of: self)) + "("
            + [x, y, z]
            .map { (v: Vector3) -> String in
                "[" + [v.x, v.y, v.z].map { String(describing: $0) }.joined(separator: ", ") + "]"
            }
            .joined(separator: ", ") + ")"
    }
}

extension Transform2D {
    @inline(__always)
    public subscript(_ column: Int, _ row: Int) -> Float {
        get {
            self[column][row]
        }

        set {
            self[column][row] = newValue
        }
    }

    @inline(__always)
    public subscript(column: Int) -> Vector3 {
        get {
            switch column {
            case 0: return x
            case 1: return y
            case 2: return z
            default: preconditionFailure("Matrix index out of range")
            }
        }
        set {
            switch column {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            default: preconditionFailure("Matrix index out of range")
            }
        }
    }

    @inline(__always)
    public static let identity: Transform2D = Transform2D()
}

extension Transform2D {
    /// Rotation in radians
    public var rotation: Float {
        get {
            return atan2(self[0].y, self[0].x)
        }

        set {
            let scale = self.scale
            let cosRotation = cos(newValue)
            let sinRotation = sin(newValue)
            self[0, 0] = cosRotation
            self[0, 1] = sinRotation
            self[1, 0] = -sinRotation
            self[1, 1] = cosRotation
            self.scale = scale
        }
    }

    public var position: Vector2 {
        get {
            Vector2(self[2, 0], self[2, 1])
        }

        set {
            self[2, 0] = newValue.x
            self[2, 1] = newValue.y
        }
    }

    public var scale: Vector2 {
        get {
            Vector2(self.x.length, self.y.length)
        }

        set {
            self.x = self.x.normalized
            self.y = self.y.normalized

            self.x *= newValue.x
            self.y *= newValue.y
        }
    }
}

extension Transform2D {
    public func rotated(by angle: Angle) -> Transform2D {
        var mat = self
        mat.rotation = angle.radians
        return mat
    }

    public func translatedBy(x: Float, y: Float) -> Transform2D {
        var mat = self
        mat.position = [x, y]
        return mat
    }

    public func scaledBy(x: Float, y: Float) -> Transform2D {
        var mat = self
        mat.scale = [x, y]
        return mat
    }
}

extension Transform2D: Equatable {}

extension Transform2D {
    public static func * (lhs: borrowing Transform2D, rhs: Float) -> Transform2D {
        Transform2D(columns: [
            [lhs[0, 0] * rhs, lhs[0, 1] * rhs, lhs[0, 2] * rhs],
            [lhs[1, 0] * rhs, lhs[1, 1] * rhs, lhs[1, 2] * rhs],
            [lhs[2, 0] * rhs, lhs[2, 1] * rhs, lhs[2, 2] * rhs],
        ])
    }

    public static func * (lhs: borrowing Transform2D, rhs: borrowing Transform2D) -> Transform2D {
        var x: Vector3 = lhs.x * rhs[0].x
        x = x + lhs.y * rhs[0].y
        x = x + lhs.z * rhs[0].z
        var y: Vector3 = lhs.x * rhs[1].x
        y = y + lhs.y * rhs[1].y
        y = y + lhs.z * rhs[1].z
        var z: Vector3 = lhs.x * rhs[2].x
        z = z + lhs.y * rhs[2].y
        z = z + lhs.z * rhs[2].z
        return Transform2D(x, y, z)
    }

    public static prefix func - (matrix: borrowing Transform2D) -> Transform2D {
        Transform2D(columns: [
            [-matrix[0, 0], -matrix[0, 1], -matrix[0, 2]],
            [-matrix[1, 0], -matrix[1, 1], -matrix[1, 2]],
            [-matrix[2, 0], -matrix[2, 1], -matrix[2, 2]],
        ])
    }
}

extension Transform2D {
    public var inverse: Transform2D {
        var mm = Transform2D()
        mm.x.x = self.y.y * self.z.z
        mm.x.x = mm.x.x - self.y.z * self.z.y
        mm.y.x = self.y.z * self.z.x
        mm.y.x = mm.y.x - self.y.x * self.z.z
        mm.z.x = self.y.x * self.z.y
        mm.z.x = mm.z.x - self.y.y * self.z.x
        mm.x.y = self.x.z * self.z.y
        mm.x.y = mm.x.y - self.x.y * self.z.z
        mm.y.y = self.x.x * self.z.z
        mm.y.y = mm.y.y - self.x.z * self.z.x
        mm.z.y = self.x.y * self.z.x
        mm.z.y = mm.z.y - self.x.x * self.z.y
        mm.x.z = self.x.y * self.y.z
        mm.x.z = mm.x.z - self.x.z * self.y.y
        mm.y.z = self.x.z * self.y.x
        mm.y.z = mm.y.z - self.x.x * self.y.z
        mm.z.z = self.x.x * self.y.y
        mm.z.z = mm.z.z - self.x.y * self.y.x
        return mm * (1 / self.determinant)
    }

    public var transpose: Transform2D {
        return Transform2D(columns: [
            [self.x.x, self.y.x, self.z.x],
            [self.x.y, self.y.y, self.z.y],
            [self.x.z, self.y.z, self.z.z],
        ])
    }

    public var determinant: Float {
        var d1 = self.y.y * self.z.z
        d1 = d1 - self.z.y * self.y.z
        var d2 = self.x.y * self.z.z
        d2 = d2 - self.z.y * self.x.z
        var d3 = self.x.y * self.y.z
        d3 = d3 - self.y.y * self.x.z
        var det = self.x.x * d1
        det = det - self.y.x * d2
        det = det + self.z.x * d3
        return det
    }

    public var isAffineMatrix: Bool {
        return self[0, 2] == 0 && self[1, 2] == 0 && self[2, 2] == 1
    }
}

extension Transform2D {
    public init(affineTransformFrom t: borrowing Transform3D) {
        let pos = t.origin
        self = Transform2D(
            [t[0, 0], t[1, 0], 0],
            [t[0, 1], t[1, 1], 0],
            [pos.x, pos.y, 1]
        )
    }
}
// swiftlint:enable identifier_name
