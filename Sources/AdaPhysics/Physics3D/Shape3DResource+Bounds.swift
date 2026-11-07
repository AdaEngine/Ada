import Math

extension Shape3DResource {
    static func calculateBounds(_ fixture: Fixture) -> AABB? {
        let result: AABB
        switch fixture {
        case let .box(shape): result = AABB(min: shape.center - shape.halfExtents, max: shape.center + shape.halfExtents)
        case let .sphere(shape):
            let radius = Vector3(shape.radius, shape.radius, shape.radius)
            result = AABB(min: shape.center - radius, max: shape.center + radius)
        case let .triangleMesh(mesh):
            guard let first = mesh.vertices.first else {
                return nil
            }
            var lower = first, upper = first
            for vertex in mesh.vertices.dropFirst() { lower = min(lower, vertex); upper = max(upper, vertex) }
            result = AABB(min: lower, max: upper)
        }
        let lower = result.min, upper = result.max
        guard lower.x.isFinite, lower.y.isFinite, lower.z.isFinite, upper.x.isFinite, upper.y.isFinite, upper.z.isFinite,
            lower.x <= upper.x, lower.y <= upper.y, lower.z <= upper.z
        else { return nil }
        return result
    }
}
