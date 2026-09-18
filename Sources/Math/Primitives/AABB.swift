//
//  AABB.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/7/23.
//

/// An axis-aligned bounding box.
public struct AABB: Equatable, Hashable, Codable, Sendable {
    public var center: Vector3
    public var halfExtents: Vector3

    public var min: Vector3 {
        return self.center - self.halfExtents
    }

    public var max: Vector3 {
        return self.center + self.halfExtents
    }

    /// Creates a bounding box with the given settings.
    public init(min: Vector3, max: Vector3) {
        self.center = (max + min) * 0.5
        self.halfExtents = [max.x - center.x, max.y - center.y, max.z - center.z]
    }

    /// Creates a bounding box with the given settings.
    public init(center: Vector3, halfExtents: Vector3) {
        self.center = center
        self.halfExtents = halfExtents
    }

    /// Creates an empty bounding box.
    public init() {
        self.halfExtents = .zero
        self.center = .zero
    }

    /// A Boolean that indicates whether a box is empty.
    public var isEmpty: Bool {
        self.halfExtents == .zero && self.center == .zero
    }
}

extension AABB {
    /// An empty bounding box.
    public static let empty: AABB = AABB()

    @inline(__always)
    public func radiusRelative(to plane: Plane, axes: [Vector3]) -> Float {
        Vector3(
            abs(plane.normal.dot(axes[0])),
            abs(plane.normal.dot(axes[1])),
            abs(plane.normal.dot(axes[2]))
        )
        .dot(self.halfExtents)
    }
}
