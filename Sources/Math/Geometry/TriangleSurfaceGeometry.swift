enum TriangleSurfaceGeometry {
    static func point(_ value: Vector3) -> ScalarMeshPoint { SIMD3(Double(value.x), Double(value.y), Double(value.z)) }
    static func finite(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }

    static func intersects(_ node: ScalarMeshNode, origin: ScalarMeshPoint, direction: ScalarMeshPoint, maximumDistance: Double) -> Bool {
        var near = 0.0, far = maximumDistance
        for axis in 0..<3 {
            if direction[axis] == 0 {
                if origin[axis] < node.low[axis] || origin[axis] > node.high[axis] {
                    return false
                }
            } else {
                let first = (node.low[axis] - origin[axis]) / direction[axis], second = (node.high[axis] - origin[axis]) / direction[axis]
                near = max(near, min(first, second)); far = min(far, max(first, second))
                if near > far {
                    return false
                }
            }
        }
        return true
    }

    private static func inside(_ point: ScalarMeshPoint, triangle: ScalarMeshTriangle) -> Bool {
        let n = triangle.normal
        for edge in 0..<3 {
            let a = triangle.point(edge), b = triangle.point((edge + 1) % 3)
            if scalarMeshDot(n, scalarMeshCross(b - a, point - a)) < 0 {
                return false
            }
        }
        return true
    }

    static func rayHit(_ triangle: ScalarMeshTriangle, origin: ScalarMeshPoint, direction: ScalarMeshPoint, maximumDistance: Double) -> (Double, ScalarMeshPoint)? {
        // A common ray-space shear gives adjacent faces the same signed edge tests.
        // No containment tolerance expands the triangle beyond its finite boundary.
        let absolute = SIMD3(abs(direction.x), abs(direction.y), abs(direction.z))
        let z = absolute.x >= absolute.y && absolute.x >= absolute.z ? 0 : absolute.y >= absolute.z ? 1 : 2
        var x = (z + 1) % 3, y = (x + 1) % 3
        if direction[z] < 0 { swap(&x, &y) }
        let sx = direction[x] / direction[z], sy = direction[y] / direction[z], sz = 1 / direction[z]
        func project(_ point: ScalarMeshPoint) -> ScalarMeshPoint {
            let relative = point - origin
            return SIMD3(relative[x] - sx * relative[z], relative[y] - sy * relative[z], relative[z] * sz)
        }
        let a = project(triangle.a), b = project(triangle.b), c = project(triangle.c)
        let u = c.x * b.y - c.y * b.x, v = a.x * c.y - a.y * c.x, w = b.x * a.y - b.y * a.x
        if (u < 0 || v < 0 || w < 0) && (u > 0 || v > 0 || w > 0) {
            return nil
        }
        let determinant = u + v + w
        guard determinant != 0 else {
            return nil
        }
        let distance = (u * a.z + v * b.z + w * c.z) / determinant
        guard distance >= 0, distance <= maximumDistance else {
            return nil
        }
        let position = triangle.a * (u / determinant) + triangle.b * (v / determinant) + triangle.c * (w / determinant)
        return (distance, position)
    }

    static func closestPoint(_ point: ScalarMeshPoint, triangle: ScalarMeshTriangle) -> ScalarMeshPoint {
        let n = triangle.normal
        let projected = point - n * (scalarMeshDot(n, point - triangle.a) / scalarMeshDot(n, n))
        if inside(projected, triangle: triangle) {
            return projected
        }
        var best = Double.infinity, result = triangle.a
        for edge in 0..<3 {
            let a = triangle.point(edge), delta = triangle.point((edge + 1) % 3) - a
            let fraction = max(0, min(1, scalarMeshDot(point - a, delta) / scalarMeshDot(delta, delta)))
            let candidate = a + delta * fraction, difference = candidate - point, squared = scalarMeshDot(difference, difference)
            if squared < best { best = squared; result = candidate }
        }
        return result
    }

    static func hit(_ position: ScalarMeshPoint, distance: Double, triangle: ScalarMeshTriangle) -> TriangleSurfaceHit {
        let n = triangle.normal, normal = n / scalarMeshDot(n, n).squareRoot()
        return .init(
            position: Vector3(Float(position.x), Float(position.y), Float(position.z)),
            normal: Vector3(Float(normal.x), Float(normal.y), Float(normal.z)),
            distance: Float(distance),
            preciseDistance: distance,
            triangleIndex: triangle.sourceIndex
        )
    }
}
