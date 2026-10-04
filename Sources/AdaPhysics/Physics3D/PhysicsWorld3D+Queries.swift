import box3d
import Math

extension PhysicsWorld3D {
    /// Vertical support sweep: snaps the lower sphere without adding tangential plane-solver motion.
    @MainActor
    func groundHeight(position: Vector3, radius: Float, distance: Float, minimumNormalY: Float) -> Float? {
        let lift: Float = 0.03
        let origin = position + Vector3(0, radius + lift, 0)
        var center = b3Vec3(x: 0, y: 0, z: 0)
        var result = GroundQuery(minimumNormalY: minimumNormalY)
        let filter = unsafe b3DefaultQueryFilter()
        unsafe withUnsafePointer(to: &center) { point in
            var proxy = b3ShapeProxy(points: point, count: 1, radius: radius)
            unsafe withUnsafeMutablePointer(to: &result) { context in
                _ = unsafe b3World_CastShape(worldId, origin.b3Vec, &proxy, Vector3(0, -distance - lift, 0).b3Vec, filter, noteGroundCast, context)
            }
        }
        return result.fraction <= 1 ? position.y + lift - (distance + lift) * result.fraction : nil
    }

    /// Sweeps a sphere against solid bodies, returning the nearest travel fraction in 0...1.
    /// Sensors are ignored. An initially overlapping sphere or invalid input returns zero.
    /// Call between physics steps, on the same serialized world that owns the bodies.
    @MainActor
    public func sphereCastFraction(from origin: Vector3, to destination: Vector3, radius: Float) -> Float {
        guard radius.isFinite, radius > 0,
            origin.x.isFinite, origin.y.isFinite, origin.z.isFinite,
            destination.x.isFinite, destination.y.isFinite, destination.z.isFinite
        else {
            return 0
        }
        let translation = destination - origin
        guard translation.length.isFinite else {
            return 0
        }
        var center = b3Vec3(x: 0, y: 0, z: 0)
        var fraction: Float = 1
        let filter = unsafe b3DefaultQueryFilter()
        // All pointers below are stack-scoped; Box3D completes both callbacks before returning.
        unsafe withUnsafePointer(to: &center) { point in
            var proxy = b3ShapeProxy(points: point, count: 1, radius: radius)
            unsafe withUnsafeMutablePointer(to: &fraction) { context in
                _ = unsafe b3World_OverlapShape(worldId, origin.b3Vec, &proxy, filter, noteSphereOverlap, context)
                guard unsafe context.pointee > 0, translation.length > 0 else {
                    return
                }
                _ = unsafe b3World_CastShape(worldId, origin.b3Vec, &proxy, translation.b3Vec, filter, noteSphereCast, context)
            }
        }
        return min(max(fraction, 0), 1)
    }
}

private struct GroundQuery {
    var minimumNormalY: Float
    var fraction: Float = 2
}

private func noteGroundCast(
    shape: b3ShapeId,
    point _: b3Vec3,
    normal: b3Vec3,
    fraction: Float,
    material _: UInt64,
    triangle _: Int32,
    child _: Int32,
    context: UnsafeMutableRawPointer?
) -> Float {
    guard !b3Shape_IsSensor(shape), let context = unsafe context else {
        return -1
    }
    let result = unsafe context.assumingMemoryBound(to: GroundQuery.self)
    guard normal.y >= (unsafe result.pointee.minimumNormalY) else {
        return -1
    }
    unsafe result.pointee.fraction = min(result.pointee.fraction, fraction)
    return unsafe result.pointee.fraction
}

private func noteSphereOverlap(shape: b3ShapeId, context: UnsafeMutableRawPointer?) -> Bool {
    guard !b3Shape_IsSensor(shape), let context = unsafe context else {
        return true
    }
    unsafe context.assumingMemoryBound(to: Float.self).pointee = 0
    return false
}

private func noteSphereCast(
    shape: b3ShapeId,
    point _: b3Vec3,
    normal _: b3Vec3,
    fraction: Float,
    material _: UInt64,
    triangle _: Int32,
    child _: Int32,
    context: UnsafeMutableRawPointer?
) -> Float {
    guard !b3Shape_IsSensor(shape), let context = unsafe context else {
        return -1
    }
    let result = unsafe context.assumingMemoryBound(to: Float.self)
    unsafe result.pointee = min(result.pointee, fraction)
    return unsafe result.pointee
}
