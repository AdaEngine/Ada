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
        intersectionDistance(ray: ray, matrix: transform.matrix, bounds: bounds)
    }

    static func intersectionDistance(ray: Ray, matrix: Transform3D, bounds: BoundingComponent?) -> Float? {
        guard abs(matrix.determinant) > 0.000001 else {
            return nil
        }
        let inverse = matrix.inverse
        let origin = inverse * Vector4(ray.origin.x, ray.origin.y, ray.origin.z, 1)
        let direction = inverse * Vector4(ray.direction.x, ray.direction.y, ray.direction.z, 0)
        // Do not normalize: the local ray parameter must still represent world distance.
        let localRay = Ray(origin: origin.xyz, direction: direction.xyz)
        let aabb = bounds == nil ? AABB(center: .zero, halfExtents: Vector3(0.35)) : localAABB(from: bounds)
        return rayAABBIntersectionDistance(ray: localRay, aabb: aabb)
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
