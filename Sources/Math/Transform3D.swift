//
//  Tranform3D.swift
//  AdaEngine
//
//  Created by v.prusakov on 10/19/21.
//

// swiftlint:disable identifier_name

// TODO: (Vlad) Check all math using https://github.com/nicklockwood/VectorMath/blob/master/VectorMath/VectorMath.swift

// Columns
//
//  x  y  z  w
// [1, 0, 0, 0]
// [0, 1, 0, 0]
// [0, 0, 1, 0]
// [0, 0, 0, 1]
//

/// The 3D transformation matrix 4x4 (column major). This matrix can represent transformations such as translation, rotation or scaling.
@frozen public struct Transform3D: Hashable, Codable, Sendable {
    public var x: Vector4
    public var y: Vector4
    public var z: Vector4
    public var w: Vector4

    @inline(__always)
    public init() {
        self.x = Vector4(1, 0, 0, 0)
        self.y = Vector4(0, 1, 0, 0)
        self.z = Vector4(0, 0, 1, 0)
        self.w = Vector4(0, 0, 0, 1)
    }
}

extension Transform3D {
    @inline(__always)
    public init(scale: borrowing Vector3) {
        self = Transform3D(diagonal: scale)
    }

    @inline(__always)
    public init(translation: borrowing Vector3) {
        self.x = Vector4(1, 0, 0, 0)
        self.y = Vector4(0, 1, 0, 0)
        self.z = Vector4(0, 0, 1, 0)
        self.w = Vector4(translation.x, translation.y, translation.z, 1)
    }

    @inline(__always)
    public init(diagonal: borrowing Vector3) {
        var matrix = Self.identity
        matrix[0, 0] = diagonal.x
        matrix[1, 1] = diagonal.y
        matrix[2, 2] = diagonal.z
        self = matrix
    }

    @inline(__always)
    public init(columns: borrowing [Vector4]) {
        precondition(columns.count == 4, "Inconsist columns count")
        self.x = columns[0]
        self.y = columns[1]
        self.z = columns[2]
        self.w = columns[3]
    }

    @inline(__always)
    public init(rows: borrowing [Vector4]) {
        precondition(rows.count == 4, "Inconsist rows count")
        let x = rows[0]
        let y = rows[1]
        let z = rows[2]
        let w = rows[3]

        self.x = [x.x, y.x, z.x, w.x]
        self.y = [x.y, y.y, z.y, w.y]
        self.z = [x.z, y.z, z.z, w.z]
        self.w = [x.w, y.w, z.w, w.w]
    }

    @inline(__always)
    public init(_ x: consuming Vector4, _ y: consuming Vector4, _ z: consuming Vector4, _ w: consuming Vector4) {
        self.x = x
        self.y = y
        self.z = z
        self.w = w
    }

    @inline(__always)
    public init(x: consuming Vector4, y: consuming Vector4, z: consuming Vector4, w: consuming Vector4) {
        self.init(x, y, z, w)
    }

    // TODO: (Vlad) check that's ok
    @inline(__always)
    public init(basis: borrowing Transform2D) {
        var matrix = Self.identity

        matrix[0, 0] = basis.x.x
        matrix[0, 1] = basis.x.y
        matrix[0, 2] = basis.x.z

        matrix[1, 0] = basis.y.x
        matrix[1, 1] = basis.y.y
        matrix[1, 2] = basis.y.z

        matrix[2, 0] = basis.z.x
        matrix[2, 1] = basis.z.y
        matrix[2, 2] = basis.z.z

        self = matrix
    }
}

// MARK: - Affine

extension Transform3D {
    /*
     | a b 0 |      | a b 0 0 |
     | d e 0 |  =>  | d e 0 0 |
     | g h 1 |      | 0 0 1 0 |
                    | g h 0 1 |
     */
    // FIXME: (Vlad) Looks like it doesn't works
    @inline(__always)
    public init(fromAffineTransform at: borrowing Transform2D) {
        self = Transform3D(columns: [
            [at[0, 0], at[1, 0], 0, at[2, 0]],
            [at[0, 1], at[1, 1], 0, at[2, 1]],
            [0, 0, 1, 0],
            [0, 0, 0, 1],
        ])
    }
}

extension Transform3D: CustomDebugStringConvertible {
    public var debugDescription: String {
        return String(describing: type(of: self)) + "("
            + [x, y, z, w]
            .map { (v: Vector4) -> String in
                "[" + [v.x, v.y, v.z, v.w].map { String(describing: $0) }.joined(separator: ", ") + "]"
            }
            .joined(separator: ", ") + ")"
    }
}

extension Transform3D {
    /// Get value from matrix.
    /// - Parameter column: a column in matrix.
    /// - Parameter row: a row in matrix.
    /// - Returns: matrix value.
    public subscript(_ column: Int, _ row: Int) -> Float {
        get {
            self[column][row]
        }

        set {
            self[column][row] = newValue
        }
    }

    public subscript(column: Int) -> Vector4 {
        get {
            switch column {
            case 0: return x
            case 1: return y
            case 2: return z
            case 3: return w
            default: preconditionFailure("Matrix index out of range")
            }
        }
        set {
            switch column {
            case 0: x = newValue
            case 1: y = newValue
            case 2: z = newValue
            case 3: w = newValue
            default: preconditionFailure("Matrix index out of range")
            }
        }
    }

    public func row(at index: Int) -> Vector4 {
        switch index {
        case 0: return [x.x, y.x, z.x, w.x]
        case 1: return [x.y, y.y, z.y, w.y]
        case 2: return [x.z, y.z, z.z, w.z]
        case 3: return [x.w, y.w, z.w, w.w]
        default: preconditionFailure("Matrix index out of range")
        }
    }

    /// Transform3D with no translation, rotation or scaling applied.
    ///
    /// ```swift
    /// [1, 0, 0, 0]
    /// [0, 1, 0, 0]
    /// [0, 0, 1, 0]
    /// [0, 0, 0, 1]
    /// ```
    @inline(__always) public static let identity: Transform3D = Transform3D()
}

extension Transform3D {
    /// Return upper left matrix 3x3.
    public var basis: Transform2D {
        return Transform2D(columns: [
            [self.x.x, self.x.y, self.x.z],
            [self.y.x, self.y.y, self.y.z],
            [self.z.x, self.z.y, self.z.z],
        ])
    }

    /// The scale of the transform.
    public var scale: Vector3 {
        get {
            let basis = self.basis
            let scaleX = basis.x.length
            let scaleY = basis.y.length
            let scaleZ = basis.z.length

            return Vector3(scaleX, scaleY, scaleZ)
        }

        set {
            self = Transform3D(scale: newValue) * self
        }
    }

    /// The rotation of the transform.
    /// - SeeAlso: http://www.euclideanspace.com/maths/geometry/rotations/conversions/matrixToQuaternion/index.htm
    /// - Note: Formula adapted for column-major matrix where self[column, row] accesses elements.
    ///         Standard formula uses m[row, col], so m_rc = self[c, r].
    public var rotation: Quat {
        var quat = Quat.identity

        let trace = self[0, 0] + self[1, 1] + self[2, 2]

        if trace > 0 {
            let s = sqrt(trace + 1.0) * 2
            quat.w = 0.25 * s
            quat.x = (self[1, 2] - self[2, 1]) / s
            quat.y = (self[2, 0] - self[0, 2]) / s
            quat.z = (self[0, 1] - self[1, 0]) / s
        } else if (self[0, 0] > self[1, 1]) && (self[0, 0] > self[2, 2]) {
            let s = sqrt(1.0 + self[0, 0] - self[1, 1] - self[2, 2]) * 2  // S=4*qx
            quat.w = (self[1, 2] - self[2, 1]) / s
            quat.x = 0.25 * s
            quat.y = (self[1, 0] + self[0, 1]) / s
            quat.z = (self[2, 0] + self[0, 2]) / s
        } else if self[1, 1] > self[2, 2] {
            let s = sqrt(1.0 + self[1, 1] - self[0, 0] - self[2, 2]) * 2  // S=4*qy
            quat.w = (self[2, 0] - self[0, 2]) / s
            quat.x = (self[1, 0] + self[0, 1]) / s
            quat.y = 0.25 * s
            quat.z = (self[2, 1] + self[1, 2]) / s
        } else {
            let s = sqrt(1.0 + self[2, 2] - self[0, 0] - self[1, 1]) * 2  // S=4*qz
            quat.w = (self[0, 1] - self[1, 0]) / s
            quat.x = (self[2, 0] + self[0, 2]) / s
            quat.y = (self[2, 1] + self[1, 2]) / s
            quat.z = 0.25 * s
        }

        return quat
    }

    ///  The translation offset of the transform
    public var origin: Vector3 {
        get {
            return Vector3(self[3, 0], self[3, 1], self[3, 2])
        }

        mutating set {
            self[3, 0] = newValue.x
            self[3, 1] = newValue.y
            self[3, 2] = newValue.z
        }
    }
}

extension Transform3D {
    /// - SeeAlso: https://stackoverflow.com/questions/1556260/convert-quaternion-rotation-to-rotation-matrix
    /// - Note: Formula for non-unit quaternion, compatible with simd_matrix4x4(simd_quatf).
    ///         Uses column-major matrix where self[column, row] accesses elements.
    ///         Standard formula uses m[row, col], so m_rc = self[c, r].
    public init(quat: Quat) {
        var matrix = Self.identity

        let x = quat.x
        let y = quat.y
        let z = quat.z
        let w = quat.w

        let xx = x * x
        let yy = y * y
        let zz = z * z
        let ww = w * w

        let xy = x * y
        let xz = x * z
        let xw = x * w
        let yz = y * z
        let yw = y * w
        let zw = z * w

        // Row 0: R[0,0], R[0,1], R[0,2] → self[0,0], self[1,0], self[2,0]
        matrix[0, 0] = ww + xx - yy - zz
        matrix[1, 0] = 2.0 * (xy - zw)
        matrix[2, 0] = 2.0 * (xz + yw)

        // Row 1: R[1,0], R[1,1], R[1,2] → self[0,1], self[1,1], self[2,1]
        matrix[0, 1] = 2.0 * (xy + zw)
        matrix[1, 1] = ww - xx + yy - zz
        matrix[2, 1] = 2.0 * (yz - xw)

        // Row 2: R[2,0], R[2,1], R[2,2] → self[0,2], self[1,2], self[2,2]
        matrix[0, 2] = 2.0 * (xz - yw)
        matrix[1, 2] = 2.0 * (yz + xw)
        matrix[2, 2] = ww - xx - yy + zz

        self = matrix
    }

    /// Create TRS matrix
    @inline(__always)
    public init(translation: borrowing Vector3, rotation: borrowing Quat, scale: borrowing Vector3) {
        self = Transform3D(translation: translation) * Transform3D(quat: rotation) * Transform3D(scale: scale)
    }
}

extension Transform3D {
    public static func * (lhs: borrowing Transform3D, rhs: Float) -> Transform3D {
        Transform3D(
            [lhs[0, 0] * rhs, lhs[0, 1] * rhs, lhs[0, 2] * rhs, lhs[0, 3] * rhs],
            [lhs[1, 0] * rhs, lhs[1, 1] * rhs, lhs[1, 2] * rhs, lhs[1, 3] * rhs],
            [lhs[2, 0] * rhs, lhs[2, 1] * rhs, lhs[2, 2] * rhs, lhs[2, 3] * rhs],
            [lhs[3, 0] * rhs, lhs[3, 1] * rhs, lhs[3, 2] * rhs, lhs[3, 3] * rhs]
        )
    }

    public static func * (lhs: borrowing Transform3D, rhs: borrowing Transform3D) -> Transform3D {
        var x: Vector4 = lhs.x * rhs[0].x
        x = x + lhs.y * rhs[0].y
        x = x + lhs.z * rhs[0].z
        x = x + lhs.w * rhs[0].w
        var y: Vector4 = lhs.x * rhs[1].x
        y = y + lhs.y * rhs[1].y
        y = y + lhs.z * rhs[1].z
        y = y + lhs.w * rhs[1].w
        var z: Vector4 = lhs.x * rhs[2].x
        z = z + lhs.y * rhs[2].y
        z = z + lhs.z * rhs[2].z
        z = z + lhs.w * rhs[2].w
        var w: Vector4 = lhs.x * rhs.w.x
        w = w + lhs.y * rhs[3].y
        w = w + lhs.z * rhs[3].z
        w = w + lhs.w * rhs[3].w
        return Transform3D(x, y, z, w)
    }

    public static func *= (lhs: inout Transform3D, rhs: borrowing Transform3D) {
        lhs = lhs * rhs
    }

    public static prefix func - (matrix: borrowing Transform3D) -> Transform3D {
        Transform3D(
            [-matrix[0, 0], -matrix[0, 1], -matrix[0, 2], -matrix[0, 3]],
            [-matrix[1, 0], -matrix[1, 1], -matrix[1, 2], -matrix[1, 3]],
            [-matrix[2, 0], -matrix[2, 1], -matrix[2, 2], -matrix[2, 3]],
            [-matrix[3, 0], -matrix[3, 1], -matrix[3, 2], -matrix[3, 3]]
        )
    }
}

extension Transform3D {
    /// Left-handed
    public static func lookAt(eye: borrowing Vector3, center: borrowing Vector3, up: borrowing Vector3 = .up) -> Transform3D {
        let z = (center - eye).normalized
        let x = z.cross(up).normalized
        let y = x.cross(z)

        let rotate30 = -x.dot(eye)
        let rotate31 = -y.dot(eye)
        let rotate32 = -z.dot(eye)

        return Transform3D(rows: [
            [x.x, y.x, z.x, 0],
            [x.y, y.y, z.y, 0],
            [x.z, y.z, z.z, 0],
            [rotate30, rotate31, rotate32, 1],
        ])
    }

    /// Create a left-handed perspective projection
    public static func perspective(
        fieldOfView: borrowing Angle,
        aspectRatio: Float,
        zNear: Float,
        zFar: Float
    ) -> Transform3D {
        precondition(aspectRatio > 0, "Aspect should be more than 0")

        let rotate11 = 1 / tanf(fieldOfView.radians * 0.5)
        let rotate01 = rotate11 / aspectRatio
        let rotate22 = zFar / (zFar - zNear)
        let rotate32 = -zNear * rotate22

        return Transform3D(rows: [
            [rotate01, 0, 0, 0],
            [0, rotate11, 0, 0],
            [0, 0, rotate22, rotate32],
            [0, 0, 1, 0],
        ])
    }

    /// Create a left-handed orthographic projection
    /// - SeeAlso: https://docs.microsoft.com/en-us/windows/win32/direct3d9/d3dxmatrixorthooffcenterlh
    public static func orthographic(
        left: Float,
        right: Float,
        top: Float,
        bottom: Float,
        zNear: Float,
        zFar: Float
    ) -> Transform3D {
        let m00 = 2 / (right - left)
        let m11 = 2 / (top - bottom)
        let m22 = 1 / (zFar - zNear)
        let m03 = (left + right) / (left - right)
        let m13 = (top + bottom) / (bottom - top)
        let m23 = zNear / (zNear - zFar)

        return Transform3D(rows: [
            [m00, 0, 0, m03],
            [0, m11, 0, m13],
            [0, 0, m22, m23],
            [0, 0, 0, 1],
        ])
    }

    public func rotate(angle: borrowing Angle, axis: borrowing Vector3) -> Transform3D {
        let c = cos(angle.radians)
        let s = sin(angle.radians)

        let axis = axis.normalized

        var r00 = c
        r00 += (1 - c) * axis.x * axis.x
        var r01 = (1 - c) * axis.x * axis.y
        r01 += s * axis.z
        var r02 = (1 - c) * axis.x * axis.z
        r02 -= s * axis.y

        var r10 = (1 - c) * axis.y * axis.x
        r10 -= s * axis.z
        var r11 = c
        r11 += (1 - c) * axis.y * axis.y
        var r12 = (1 - c) * axis.y * axis.z
        r12 += s * axis.x

        var r20 = (1 - c) * axis.z * axis.x
        r20 += s * axis.y
        var r21 = (1 - c) * axis.z * axis.y
        r21 -= s * axis.x
        var r22 = c
        r22 += (1 - c) * axis.z * axis.z

        return Transform3D(rows: [
            [r00, r01, r02, 0],
            [r10, r11, r12, 0],
            [r20, r21, r22, 0],
            [0, 0, 0, 1],
        ])
    }

    public func scaledBy(_ vector: borrowing Vector3) -> Transform3D {
        Transform3D(scale: vector) * self
    }

    public func translatedBy(_ vector: borrowing Vector3) -> Transform3D {
        Transform3D(translation: vector) * self
    }

    public var transpose: Transform3D {
        return Transform3D(rows: [
            [self.x.x, self.y.x, self.z.x, self.w.x],
            [self.x.y, self.y.y, self.z.y, self.w.y],
            [self.x.z, self.y.z, self.z.z, self.w.z],
            [self.x.w, self.y.w, self.z.w, self.w.w],
        ])
    }

    public var inverse: Transform3D {
        var d00 = self.x.x * self.y.y
        d00 = d00 - self.y.x * self.x.y
        var d01 = self.x.x * self.y.z
        d01 = d01 - self.y.x * self.x.z
        var d02 = self.x.x * self.y.w
        d02 = d02 - self.y.x * self.x.w
        var d03 = self.x.y * self.y.z
        d03 = d03 - self.y.y * self.x.z
        var d04 = self.x.y * self.y.w
        d04 = d04 - self.y.y * self.x.w
        var d05 = self.x.z * self.y.w
        d05 = d05 - self.y.z * self.x.w

        var d10 = self.z.x * self.w.y
        d10 = d10 - self.w.x * self.z.y
        var d11 = self.z.x * self.w.z
        d11 = d11 - self.w.x * self.z.z
        var d12 = self.z.x * self.w.w
        d12 = d12 - self.w.x * self.z.w
        var d13 = self.z.y * self.w.z
        d13 = d13 - self.w.y * self.z.z
        var d14 = self.z.y * self.w.w
        d14 = d14 - self.w.y * self.z.w
        var d15 = self.z.z * self.w.w
        d15 = d15 - self.w.z * self.z.w

        var det = d00 * d15
        det = det - d01 * d14
        det = det + d02 * d13
        det = det + d03 * d12
        det = det - d04 * d11
        det = det + d05 * d10

        var mm = Transform3D()

        mm.x.x = self.y.y * d15
        mm.x.x = mm.x.x - self.y.z * d14
        mm.x.x = mm.x.x + self.y.w * d13
        mm.x.y = 0 - self.x.y * d15
        mm.x.y = mm.x.y + self.x.z * d14
        mm.x.y = mm.x.y - self.x.w * d13
        mm.x.z = self.w.y * d05
        mm.x.z = mm.x.z - self.w.z * d04
        mm.x.z = mm.x.z + self.w.w * d03
        mm.x.w = 0 - self.z.y * d05
        mm.x.w = mm.x.w + self.z.z * d04
        mm.x.w = mm.x.w - self.z.w * d03

        mm.y.x = 0 - self.y.x * d15
        mm.y.x = mm.y.x + self.y.z * d12
        mm.y.x = mm.y.x - self.y.w * d11
        mm.y.y = self.x.x * d15
        mm.y.y = mm.y.y - self.x.z * d12
        mm.y.y = mm.y.y + self.x.w * d11
        mm.y.z = 0 - self.w.x * d05
        mm.y.z = mm.y.z + self.w.z * d02
        mm.y.z = mm.y.z - self.w.w * d01
        mm.y.w = self.z.x * d05
        mm.y.w = mm.y.w - self.z.z * d02
        mm.y.w = mm.y.w + self.z.w * d01

        mm.z.x = self.y.x * d14
        mm.z.x = mm.z.x - self.y.y * d12
        mm.z.x = mm.z.x + self.y.w * d10
        mm.z.y = 0 - self.x.x * d14
        mm.z.y = mm.z.y + self.x.y * d12
        mm.z.y = mm.z.y - self.x.w * d10
        mm.z.z = self.w.x * d04
        mm.z.z = mm.z.z - self.w.y * d02
        mm.z.z = mm.z.z + self.w.w * d00
        mm.z.w = 0 - self.z.x * d04
        mm.z.w = mm.z.w + self.z.y * d02
        mm.z.w = mm.z.w - self.z.w * d00

        mm.w.x = 0 - self.y.x * d13
        mm.w.x = mm.w.x + self.y.y * d11
        mm.w.x = mm.w.x - self.y.z * d10
        mm.w.y = self.x.x * d13
        mm.w.y = mm.w.y - self.x.y * d11
        mm.w.y = mm.w.y + self.x.z * d10
        mm.w.z = 0 - self.w.x * d03
        mm.w.z = mm.w.z + self.w.y * d01
        mm.w.z = mm.w.z - self.w.z * d00
        mm.w.w = self.z.x * d03
        mm.w.w = mm.w.w - self.z.y * d01
        mm.w.w = mm.w.w + self.z.z * d00

        let invdet = 1 / det
        return mm * invdet
    }

    public var determinant: Float {
        var d00 = self.x.x * self.y.y
        d00 = d00 - self.y.x * self.x.y
        var d01 = self.x.x * self.y.z
        d01 = d01 - self.y.x * self.x.z
        var d02 = self.x.x * self.y.w
        d02 = d02 - self.y.x * self.x.w
        var d03 = self.x.y * self.y.z
        d03 = d03 - self.y.y * self.x.z
        var d04 = self.x.y * self.y.w
        d04 = d04 - self.y.y * self.x.w
        var d05 = self.x.z * self.y.w
        d05 = d05 - self.y.z * self.x.w

        var d10 = self.z.x * self.w.y
        d10 = d10 - self.w.x * self.z.y
        var d11 = self.z.x * self.w.z
        d11 = d11 - self.w.x * self.z.z
        var d12 = self.z.x * self.w.w
        d12 = d12 - self.w.x * self.z.w
        var d13 = self.z.y * self.w.z
        d13 = d13 - self.w.y * self.z.z
        var d14 = self.z.y * self.w.w
        d14 = d14 - self.w.y * self.z.w
        var d15 = self.z.z * self.w.w
        d15 = d15 - self.w.z * self.z.w

        var det = d00 * d15
        det = det - d01 * d14
        det = det + d02 * d13
        det = det + d03 * d12
        det = det - d04 * d11
        det = det + d05 * d10

        return det
    }
}

// swiftlint:enable identifier_name
