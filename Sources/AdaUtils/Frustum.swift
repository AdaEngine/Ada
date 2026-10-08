//
//  Frustum.swift
//  AdaEngine
//
//  Created by v.prusakov on 2/7/23.
//

import Math

/// A frustum defined by the 6 containing planes
/// Planes are ordered left, right, top, bottom, near, far
/// Normals point into the contained volume
public struct Frustum: Hashable, Codable, Sendable {
    public var planes: FixedArray<Plane>

    public init(
        planes: FixedArray<Plane> = FixedArray(
            repeating: Plane(normal: .zero, d: 0),
            count: 6
        )
    ) {
        self.planes = planes
    }
}

extension Frustum: DefaultValue {
    public static let defaultValue: Frustum = Frustum()
}

extension Frustum {
    /// Check that AABB intersect the frustum.
    public func intersectsAABB(_ aabb: AABB) -> Bool {
        let aabbMin = aabb.min
        let aabbMax = aabb.max

        for unsafe plane in unsafe planes {
            guard let plane else {
                continue
            }

            let distance =
                max(aabbMin.x * plane.normal.x, aabbMax.x * plane.normal.x)
                + max(aabbMin.y * plane.normal.y, aabbMax.y * plane.normal.y)
                + max(aabbMin.z * plane.normal.z, aabbMax.z * plane.normal.z)
                + plane.d

            if distance < 0 {
                return false
            }
        }

        return true
    }
}

extension Frustum {
    public static func make(from viewProjection: Transform3D) -> Frustum {
        var frustum = Self.makeWithoutFar(from: viewProjection)
        frustum.planes[5] = Plane(normal_d: viewProjection.row(at: 2))
        return frustum
    }

    public static func makeWithoutFar(from viewProjection: Transform3D) -> Frustum {
        let row3 = viewProjection.row(at: 3)
        var frustum = Frustum()

        for index in 0..<frustum.planes.count - 1 {
            let row = viewProjection.row(at: index / 2)

            let plane: Plane

            if (index & 1) == 0 && index != 4 {
                plane = Plane(normal_d: row3 + row)
            } else {
                plane = Plane(normal_d: row3 - row)
            }

            frustum.planes[index] = plane
        }

        return frustum
    }
}
