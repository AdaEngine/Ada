//
//  Plane.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/6/23.
//

public struct Plane: Hashable, Codable, Sendable {
    public var normal: Vector3
    public var d: Float

    public var normal_d: Vector4 {
        return Vector4(normal, d)
    }

    @inline(__always)
    public init(normal: Vector3, d: Float) {
        self.normal = normal
        self.d = d
    }

    @inline(__always)
    public init(normal_d: Vector4) {
        self.normal = normal_d.xyz
        self.d = normal_d.w
    }

    @inline(__always)
    public init(point: Vector3, normal: Vector3) {
        self.normal = normal
        self.d = normal.dot(point)
    }

    @inline(__always)
    public init(a: Float, b: Float, c: Float, d: Float) {
        self.normal = [a, b, c]
        self.d = d
    }

    public func distance(to point: Vector3) -> Float {
        return normal.dot(point) - d
    }

    public func hasPoint(_ point: Vector3, epsilon: Float = 0.0001) -> Bool {
        let dist = abs(self.distance(to: point))

        return dist <= epsilon
    }
}
