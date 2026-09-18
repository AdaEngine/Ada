@_spi(AdaEngine) import AdaEngine
import Math

enum EditorPicking {
    static func contains2D(_ point: Vector2, transform: Transform, bounds: BoundingComponent?) -> Bool {
        let aabb = localAABB(from: bounds)
        let fallbackHalfExtent: Float = 0.35
        let halfX = max(abs(aabb.halfExtents.x * transform.scale.x), fallbackHalfExtent)
        let halfY = max(abs(aabb.halfExtents.y * transform.scale.y), fallbackHalfExtent)
        let center = transform.position.xy + aabb.center.xy

        return point.x >= center.x - halfX
            && point.x <= center.x + halfX
            && point.y >= center.y - halfY
            && point.y <= center.y + halfY
    }

    static func intersectionDistance(ray: Ray, transform: Transform, bounds: BoundingComponent?) -> Float? {
        let aabb = localAABB(from: bounds)
        let fallback = Vector3(0.35)
        let halfExtents = Vector3(
            max(abs(aabb.halfExtents.x * transform.scale.x), fallback.x),
            max(abs(aabb.halfExtents.y * transform.scale.y), fallback.y),
            max(abs(aabb.halfExtents.z * transform.scale.z), fallback.z)
        )
        let worldAABB = AABB(center: transform.position + aabb.center, halfExtents: halfExtents)
        return rayAABBIntersectionDistance(ray: ray, aabb: worldAABB)
    }

    static func perspectiveRay(
        point: Point,
        viewportSize: Size,
        cameraPosition: Vector3,
        front: Vector3,
        right: Vector3,
        verticalFieldOfView: Angle
    ) -> Ray {
        let safeWidth = max(1, viewportSize.width)
        let safeHeight = max(1, viewportSize.height)
        let ndc = Vector2(
            (point.x / safeWidth) * 2 - 1,
            1 - (point.y / safeHeight) * 2
        )
        // Match the camera basis used by EditorSceneViewportModel.cameraState.
        // Reversing these operands mirrors every off-center ray vertically.
        let up = front.cross(right).normalized
        let verticalScale = Math.tanf(verticalFieldOfView.radians * 0.5)
        let horizontalScale = verticalScale * safeWidth / safeHeight
        let direction =
            (front
            + right * ndc.x * horizontalScale
            + up * ndc.y * verticalScale)
            .normalized
        return Ray(origin: cameraPosition, direction: direction)
    }

    static func rayAABBIntersectionDistance(ray: Ray, aabb: AABB) -> Float? {
        let minPoint = aabb.min
        let maxPoint = aabb.max
        var tMin: Float = -.greatestFiniteMagnitude
        var tMax: Float = .greatestFiniteMagnitude

        for axis in 0..<3 {
            let origin = ray.origin[axis]
            let direction = ray.direction[axis]
            let minValue = minPoint[axis]
            let maxValue = maxPoint[axis]

            if abs(direction) < 0.000_001 {
                if origin < minValue || origin > maxValue {
                    return nil
                }
                continue
            }

            let inverseDirection = 1 / direction
            var near = (minValue - origin) * inverseDirection
            var far = (maxValue - origin) * inverseDirection
            if near > far {
                swap(&near, &far)
            }
            tMin = Swift.max(tMin, near)
            tMax = Swift.min(tMax, far)
            if tMin > tMax {
                return nil
            }
        }

        if tMax < 0 {
            return nil
        }
        return Swift.max(0, tMin)
    }

    private static func localAABB(from bounds: BoundingComponent?) -> AABB {
        guard let bounds else {
            return .empty
        }
        switch bounds.bounds {
        case let .aabb(aabb):
            return aabb
        }
    }
}
