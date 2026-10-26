import AdaECS
import box3d
import Math

/// Closest solid surface reached by a finite world-space segment.
public struct Raycast3DHit: Sendable {
    public let entityID: Entity.ID?
    public let position: Vector3
    public let normal: Vector3
    public let fraction: Float
    public let distance: Float
}

extension PhysicsWorld3D {
    /// Queries the current native world between physics steps. Sensors are ignored
    /// by default; a missing entity association still represents a blocking hit.
    @MainActor
    public func raycast(
        from origin: Vector3,
        to destination: Vector3,
        excluding entity: Entity.ID? = nil,
        includeSensors: Bool = false
    ) -> Raycast3DHit? {
        guard validRaySegment3D(origin, destination) else { return nil }
        let translation = destination - origin
        var collector = RaycastCollector3D(ignoredEntity: entity, includeSensors: includeSensors)
        unsafe withUnsafeMutablePointer(to: &collector) { context in
            _ = unsafe b3World_CastRay(worldId, origin.b3Vec, translation.b3Vec,
                b3DefaultQueryFilter(), collectRaycast3D, context)
        }
        guard collector.fraction <= 1 else { return nil }
        return Raycast3DHit(entityID: collector.entityID, position: collector.position,
            normal: collector.normal, fraction: collector.fraction, distance: translation.length * collector.fraction)
    }
}

func validRaySegment3D(_ origin: Vector3, _ destination: Vector3) -> Bool {
    origin.x.isFinite && origin.y.isFinite && origin.z.isFinite
        && destination.x.isFinite && destination.y.isFinite && destination.z.isFinite
        && (destination - origin).length.isFinite && (destination - origin).squaredLength > 0.00000001
}

// Box3D completes this callback synchronously; the stack collector and Body3D
// association cannot outlive the serialized query. Results retain only value data.
private struct RaycastCollector3D {
    let ignoredEntity: Entity.ID?
    let includeSensors: Bool
    var fraction: Float = 2
    var entityID: Entity.ID?
    var position: Vector3 = .zero
    var normal: Vector3 = .zero
}

private func collectRaycast3D(
    shape: b3ShapeId, point: b3Vec3, normal: b3Vec3, fraction: Float,
    material _: UInt64, triangle _: Int32, child _: Int32, context: UnsafeMutableRawPointer?
) -> Float {
    guard let context = unsafe context else { return -1 }
    let collector = unsafe context.assumingMemoryBound(to: RaycastCollector3D.self)
    guard unsafe collector.pointee.includeSensors || !b3Shape_IsSensor(shape) else { return -1 }
    let entityID = b3Body_GetUserData(b3Shape_GetBody(shape)).flatMap { pointer in
        Unmanaged<Body3D>.fromOpaque(pointer).takeUnretainedValue().entity?.id
    }
    if let entityID, entityID == (unsafe collector.pointee.ignoredEntity) { return -1 }
    guard fraction.isFinite, fraction >= 0, fraction < (unsafe collector.pointee.fraction) else {
        return unsafe collector.pointee.fraction
    }
    unsafe collector.pointee.fraction = fraction
    unsafe collector.pointee.entityID = entityID
    unsafe collector.pointee.position = point.asVector3
    unsafe collector.pointee.normal = normal.asVector3
    return fraction
}
