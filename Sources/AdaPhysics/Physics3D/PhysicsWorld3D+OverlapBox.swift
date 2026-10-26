import AdaECS
import box3d
import Math

/// Result of an oriented-box query. The first blocking shape need not have an entity.
public struct OverlapBox3DResult: Sendable {
    public let hasOverlap: Bool
    public let entityID: Entity.ID?
}

extension PhysicsWorld3D {
    /// Tests the complete oriented box against native shapes, rather than only its AABB.
    /// Call between physics steps on the serialized world. Sensors are ignored by default.
    /// Returns nil for invalid input; nil must never be interpreted as a clear volume.
    /// A finite, safely normalizable quaternion is normalized. Touching follows Box3D's overlap tolerance.
    /// The reported entity belongs to the first accepted shape; traversal order is unspecified.
    @MainActor
    public func overlapBox(
        center: Vector3,
        halfExtents: Vector3,
        rotation: Quat = .identity,
        excluding entity: Entity.ID? = nil,
        includeSensors: Bool = false
    ) -> OverlapBox3DResult? {
        guard center.x.isFinite, center.y.isFinite, center.z.isFinite, center.squaredLength.isFinite,
            halfExtents.x.isFinite, halfExtents.y.isFinite, halfExtents.z.isFinite,
            halfExtents.x > 0, halfExtents.y > 0, halfExtents.z > 0, halfExtents.squaredLength.isFinite,
            rotation.x.isFinite, rotation.y.isFinite, rotation.z.isFinite, rotation.w.isFinite,
            rotation.squaredLength.isFinite, rotation.squaredLength > 0
        else { return nil }
        let q = rotation.normalized
        guard q.squaredLength.isFinite, abs(q.squaredLength - 1) < 0.0001 else { return nil }
        let axis = Vector3(q.x, q.y, q.z)
        // Box3D finishes the callback before returning. Proxy points and collector
        // stay within these stack-scoped borrows; only value data leaves the query.
        return unsafe withUnsafeTemporaryAllocation(of: b3Vec3.self, capacity: 8) { points -> OverlapBox3DResult? in
            for index in 0..<8 {
                let corner = Vector3(
                    index & 1 == 0 ? -halfExtents.x : halfExtents.x,
                    index & 2 == 0 ? -halfExtents.y : halfExtents.y,
                    index & 4 == 0 ? -halfExtents.z : halfExtents.z
                )
                let twice = axis.cross(corner) * 2
                let rotated = corner + twice * q.w + axis.cross(twice)
                guard rotated.x.isFinite, rotated.y.isFinite, rotated.z.isFinite, rotated.squaredLength.isFinite else { return nil }
                unsafe points[index] = rotated.b3Vec
            }
            var proxy = unsafe b3ShapeProxy(points: points.baseAddress, count: 8, radius: 0)
            var collector = BoxOverlapCollector3D(ignoredEntity: entity, includeSensors: includeSensors)
            unsafe withUnsafeMutablePointer(to: &collector) { context in
                _ = unsafe b3World_OverlapShape(worldId, center.b3Vec, &proxy,
                    b3DefaultQueryFilter(), collectBoxOverlap3D, context)
            }
            return OverlapBox3DResult(hasOverlap: collector.hasOverlap, entityID: collector.entityID)
        }
    }
}

private struct BoxOverlapCollector3D {
    let ignoredEntity: Entity.ID?
    let includeSensors: Bool
    var hasOverlap = false
    var entityID: Entity.ID?
}

private func collectBoxOverlap3D(shape: b3ShapeId, context: UnsafeMutableRawPointer?) -> Bool {
    guard let context = unsafe context else { return false }
    let collector = unsafe context.assumingMemoryBound(to: BoxOverlapCollector3D.self)
    guard unsafe collector.pointee.includeSensors || !b3Shape_IsSensor(shape) else { return true }
    let entityID = b3Body_GetUserData(b3Shape_GetBody(shape)).flatMap { pointer in
        Unmanaged<Body3D>.fromOpaque(pointer).takeUnretainedValue().entity?.id
    }
    if let entityID, entityID == (unsafe collector.pointee.ignoredEntity) { return true }
    unsafe collector.pointee.hasOverlap = true
    unsafe collector.pointee.entityID = entityID
    return false
}
