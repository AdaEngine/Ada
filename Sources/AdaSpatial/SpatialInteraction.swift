import AdaECS
import AdaTransform
import Math

/// Marks a root entity as manipulable. Bounds are local half extents in meters.
/// Parent transforms are not supported by this initial spatial manipulation path.
@Component
public struct SpatialGrabbable: Sendable {
    public var halfExtents: Vector3
    public var directGrabMargin: Float

    public init(halfExtents: Vector3, directGrabMargin: Float = 0.06) {
        self.halfExtents = halfExtents
        self.directGrabMargin = directGrabMargin
    }
}

/// Selection survives release so an inspector can continue editing the last selected object.
public struct SpatialSelection: Resource {
    public var entityID: Entity.ID?
    public var isGrabbed: Bool

    public init(entityID: Entity.ID? = nil, isGrabbed: Bool = false) {
        self.entityID = entityID
        self.isGrabbed = isGrabbed
    }
}

/// Keeps offsets at grab time and rebases whenever the number of gripping hands changes.
struct SpatialGrabSession {
    var entityID: Entity.ID
    var interactors: [SpatialInteractor]
    var objectStart: Transform
    var poseStart: Transform3D
    var secondaryStart: Vector3?

    init(entityID: Entity.ID, object: Transform, grips: [SpatialGrip]) {
        self.entityID = entityID
        self.interactors = grips.map(\.interactor)
        self.objectStart = object
        self.poseStart = grips[0].pose
        self.secondaryStart = grips.count == 2 ? grips[1].pose.origin : nil
    }

    func transform(grips: [SpatialGrip]) -> Transform {
        guard let first = grips.first else {
            return objectStart
        }
        guard let secondaryStart, grips.count == 2 else {
            let delta = first.pose * poseStart.inverse
            return Transform(
                rotation: (Transform3D(quat: delta.rotation) * Transform3D(quat: objectStart.rotation)).rotation,
                scale: objectStart.scale,
                position: (delta * Vector4(objectStart.position, 1)).xyz
            )
        }
        let startVector = secondaryStart - poseStart.origin
        let currentVector = grips[1].pose.origin - first.pose.origin
        guard startVector.length > 0.02, currentVector.length > 0.02 else {
            return objectStart
        }
        let ratio = min(max(currentVector.length / startVector.length, 0.1), 10)
        let rotation = Self.rotation(from: startVector.normalized, to: currentVector.normalized)
        let startCenter = (secondaryStart + poseStart.origin) * 0.5
        let currentCenter = (grips[1].pose.origin + first.pose.origin) * 0.5
        let rotatedOffset = (Transform3D(quat: rotation) * Vector4((objectStart.position - startCenter) * ratio, 0)).xyz
        return Transform(
            rotation: (Transform3D(quat: rotation) * Transform3D(quat: objectStart.rotation)).rotation,
            scale: objectStart.scale * ratio,
            position: currentCenter + rotatedOffset
        )
    }

    private static func rotation(from start: Vector3, to end: Vector3) -> Quat {
        let dot = min(max(start.dot(end), -1), 1)
        if dot > 0.9999 {
            return .identity
        }
        if dot < -0.9999 {
            let axis = start.cross(abs(start.x) < 0.9 ? Vector3(1, 0, 0) : Vector3(0, 1, 0)).normalized
            return Quat(axis: axis, angle: .pi)
        }
        let cross = start.cross(end)
        let divisor = Math.sqrt(2 * (1 + dot))
        return Quat(x: cross.x / divisor, y: cross.y / divisor, z: cross.z / divisor, w: divisor * 0.5)
    }
}

/// One object may be held by up to two interactors. Changes apply through writable ECS queries.
@PlainSystem
public struct SpatialInteractionSystem {
    @Query<Entity, Ref<Transform>, SpatialGrabbable> private var objects
    @Res<SpatialInput> private var input
    @ResMut<SpatialSelection> private var selection
    @Local private var session: SpatialGrabSession?
    @Local private var previousInteractors: Set<SpatialInteractor> = []

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        // Reject invalid poses before they can poison a scene transform.
        let grips = input.grips.filter { grip in
            abs(grip.pose.determinant) > 0.0001
                && (0..<4).allSatisfy { column in
                    (0..<4).allSatisfy { row in grip.pose[column, row].isFinite }
                }
        }
        let current = Set(grips.map(\.interactor))
        defer { previousInteractors = current }
        if let active = session {
            var found = false
            objects.forEach { entity, transform, bounds in
                guard entity.id == active.entityID else {
                    return
                }
                found = true
                let held = active.interactors.compactMap { interactor in grips.first { $0.interactor == interactor } }
                guard !held.isEmpty else {
                    session = nil
                    return
                }
                var attached = held
                if attached.count == 1,
                    let joining = grips.first(where: {
                        !active.interactors.contains($0.interactor)
                            && !previousInteractors.contains($0.interactor)
                            && Self.hitDistance($0, transform: transform.wrappedValue, bounds: bounds) != nil
                    }) {
                    attached.append(joining)
                }
                if attached.map(\.interactor) != active.interactors {
                    // Rebase at the current transform: adding/releasing a hand must not jump.
                    session = SpatialGrabSession(entityID: entity.id, object: transform.wrappedValue, grips: attached)
                } else {
                    transform.wrappedValue = active.transform(grips: attached)
                }
            }
            if !found {
                session = nil
                selection.entityID = nil
            }
        } else {
            // A held pinch that started in empty space must not suddenly acquire an object.
            for grip in grips where !previousInteractors.contains(grip.interactor) {
                var candidate: (Entity.ID, Transform, Float)?
                objects.forEach { entity, transform, bounds in
                    if let distance = Self.hitDistance(grip, transform: transform.wrappedValue, bounds: bounds),
                        candidate == nil || distance < (candidate?.2 ?? .infinity) {
                        candidate = (entity.id, transform.wrappedValue, distance)
                    }
                }
                if let candidate {
                    session = SpatialGrabSession(entityID: candidate.0, object: candidate.1, grips: [grip])
                    selection.entityID = candidate.0
                    break
                }
            }
        }
        selection.isGrabbed = session != nil
    }

    private static func hitDistance(_ grip: SpatialGrip, transform: Transform, bounds: SpatialGrabbable) -> Float? {
        guard transform.scale.x > 0, transform.scale.y > 0, transform.scale.z > 0 else {
            return nil
        }
        let inverse = transform.matrix.inverse
        let extent = bounds.halfExtents
        guard extent.x > 0, extent.y > 0, extent.z > 0 else {
            return nil
        }
        guard let ray = grip.ray else {
            let local = (inverse * Vector4(grip.pose.origin, 1)).xyz
            let margin = max(0, bounds.directGrabMargin)
            if abs(local.x) <= extent.x + margin / transform.scale.x,
                abs(local.y) <= extent.y + margin / transform.scale.y,
                abs(local.z) <= extent.z + margin / transform.scale.z {
                return (grip.pose.origin - transform.position).length
            }
            return nil
        }
        guard (0..<3).allSatisfy({ ray.origin[$0].isFinite && ray.direction[$0].isFinite }) else {
            return nil
        }
        let origin = (inverse * Vector4(ray.origin, 1)).xyz
        let direction = (inverse * Vector4(ray.direction, 0)).xyz
        guard direction.length > 0.0001 else {
            return nil
        }
        var near: Float = 0
        var far: Float = .infinity
        for axis in 0..<3 {
            if abs(direction[axis]) < 0.00001 {
                if abs(origin[axis]) > extent[axis] {
                    return nil
                }
            } else {
                let a = (-extent[axis] - origin[axis]) / direction[axis]
                let b = (extent[axis] - origin[axis]) / direction[axis]
                near = max(near, min(a, b))
                far = min(far, max(a, b))
                if near > far {
                    return nil
                }
            }
        }
        return near
    }
}
