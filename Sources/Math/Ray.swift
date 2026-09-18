//
//  Ray.swift
//  AdaEngine
//
//  Created by v.prusakov on 4/5/23.
//

/// Is an inifite line starting at `origin` point going in `direction`.
@frozen public struct Ray: Hashable, Equatable, Codable {
    /// The origin point of the ray.
    public let origin: Vector3

    /// The vector representing direction of the ray.
    public let direction: Vector3

    public init(origin: Vector3, direction: Vector3) {
        self.origin = origin
        self.direction = direction
    }
}

extension Ray {
    @inlinable
    @inline(__always)
    public func point(in distance: Float) -> Vector3 {
        return self.origin + self.direction * distance
    }
}
