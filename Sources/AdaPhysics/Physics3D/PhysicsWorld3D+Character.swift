import box3d
import Math

// Box3D invokes these callbacks synchronously. Both the context and plane storage are scoped
// to one move and never escape to a task or the physics world.
@unsafe
private struct CharacterPlanes {
    var storage: UnsafeMutableBufferPointer<b3CollisionPlane>
    var count = 0
    var skin: Float
    var origin = Vector3.zero
    var blockCorners = false
    var horizontalMotion = Vector3.zero
}

private func collectCharacterPlanes(
    shape: b3ShapeId,
    results: UnsafePointer<b3PlaneResult>?,
    count: Int32,
    context: UnsafeMutableRawPointer?
) -> Bool {
    guard !b3Shape_IsSensor(shape), let results = unsafe results, let context = unsafe context else {
        return true
    }
    let planes = unsafe context.assumingMemoryBound(to: CharacterPlanes.self)
    for index in 0..<Int(count) {
        guard unsafe planes.pointee.count < planes.pointee.storage.count else {
            return false
        }
        var plane = unsafe results[index].plane
        unsafe plane.offset -= planes.pointee.skin
        let type = b3Shape_GetType(shape)
        if unsafe planes.pointee.blockCorners, type != b3_sphereShape, type != b3_capsuleShape,
            plane.normal.y > 0.01, plane.normal.y < 0.999,
            unsafe plane.normal.asVector3.dot(planes.pointee.horizontalMotion) < -0.0000001 {
            let normal = plane.normal.asVector3
            let point = unsafe planes.pointee.origin + results[index].point.asVector3
            // Read-only shape queries are synchronous. A real sloped face keeps its original
            // plane; the capsule's rounded contact with a flat ledge must not manufacture a ramp.
            let face = b3Shape_RayCast(shape, (point + normal * 0.02).b3Vec, (-normal * 0.04).b3Vec)
            if !face.hit || face.normal.y <= 0.01 || face.normal.y >= 0.999 || face.normal.asVector3.dot(normal) < 0.98 {
                let horizontal = Vector3(normal.x, 0, normal.z)
                plane.normal = horizontal.normalized.b3Vec
                // Preserve the plane solver's support slop when normalizing the constraint;
                // dividing the offset alone amplifies benign contact overlap into lateral pushes.
                let slop = 0.005 * b3GetLengthUnitsPerMeter()
                plane.offset = (plane.offset - slop) / horizontal.length + slop
            }
        }
        unsafe planes.pointee.storage[planes.pointee.count] = b3CollisionPlane(
            plane: plane, pushLimit: .greatestFiniteMagnitude, push: 0, clipVelocity: true
        )
        unsafe planes.pointee.count += 1
    }
    return true
}

private func noteCharacterHeightOverlap(shape: b3ShapeId, context: UnsafeMutableRawPointer?) -> Bool {
    guard !b3Shape_IsSensor(shape), let context = unsafe context else { return true }
    unsafe context.assumingMemoryBound(to: Bool.self).pointee = true
    return false
}

private struct CharacterLanding {
    var fraction: Float = 2
    var point = Vector3.zero
    var normal = Vector3.zero
}

private func noteCharacterLanding(
    shape: b3ShapeId, point: b3Vec3, normal: b3Vec3, fraction: Float,
    material _: UInt64, triangle _: Int32, child _: Int32, context: UnsafeMutableRawPointer?
) -> Float {
    // A tangent wall or a ceiling we are moving away from cannot block a downward sweep.
    guard !b3Shape_IsSensor(shape), normal.y > 0.0001, let context = unsafe context else { return -1 }
    let result = unsafe context.assumingMemoryBound(to: CharacterLanding.self)
    if fraction < (unsafe result.pointee.fraction) {
        unsafe result.pointee = CharacterLanding(fraction: fraction, point: point.asVector3, normal: normal.asVector3)
    }
    return unsafe result.pointee.fraction
}

extension PhysicsWorld3D {
    @MainActor
    func moveCharacter(_ controller: inout CharacterController3DComponent, position: inout Vector3, deltaTime: Float) {
        guard deltaTime.isFinite, deltaTime > 0, position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            return
        }
        resolveCharacterHeight(&controller, position: position)
        let desired = controller.desiredVelocity
        guard desired.x.isFinite, desired.z.isFinite else {
            return
        }
        let target = Vector3(desired.x, 0, desired.z)
        guard target.length.isFinite else {
            return
        }
        let jumped = controller.jumpRequested && controller.isGrounded && controller.jumpSpeed.isFinite && controller.jumpSpeed > 0
        let control = controller.airControl.isFinite ? min(max(controller.airControl, 0), 1) : 0
        // The takeoff tick retains the actual approach velocity, including when input is released
        // or the camera turns on the same frame as Jump. Contacts still clip momentum below.
        let authority: Float = controller.isGrounded && !jumped ? 1 : control
        let rate = (target.length > 0.001 ? controller.acceleration : controller.deceleration) * authority
        let change = target - controller.horizontalVelocity
        let maxChange = max(0, rate.isFinite ? rate : 0) * deltaTime
        controller.horizontalVelocity += change.length > maxChange && change.length > 0 ? change.normalized * maxChange : change
        controller.jumpRequested = false
        if jumped { controller.verticalVelocity = controller.jumpSpeed }
        let fallLimit = controller.maximumFallSpeed.isFinite ? max(0, controller.maximumFallSpeed) : 50
        let gravityY = gravity.y.isFinite ? gravity.y : -9.81
        if controller.isGrounded, !jumped {
            controller.verticalVelocity = 0
        } else { controller.verticalVelocity = max(-fallLimit, controller.verticalVelocity + gravityY * deltaTime) }
        let start = position
        let velocity = controller.horizontalVelocity + Vector3(0, controller.verticalVelocity, 0)
        let groundThreshold = controller.minimumGroundNormalY.isFinite ? min(max(controller.minimumGroundNormalY, 0.01), 1) : 0.707107
        let horizontalDelta = controller.horizontalVelocity * deltaTime
        let canStep = controller.isGrounded && !jumped && controller.verticalVelocity <= 0 && horizontalDelta.length > 0.00001
        var result = moveCapsule(position: start, radius: controller.radius, height: controller.height,
            delta: velocity * deltaTime, groundThreshold: groundThreshold, blockCorners: canStep)
        let snapDistance = controller.groundSnapDistance.isFinite ? min(max(controller.groundSnapDistance, 0), controller.radius) : 0
        if canStep, let stepped = stepCharacter(position: start, radius: controller.radius, height: controller.height,
            delta: horizontalDelta, slide: result.position, snapDistance: snapDistance, groundThreshold: groundThreshold) {
            result = (stepped, true, false)
        }
        if controller.isGrounded, !jumped, controller.verticalVelocity <= 0, snapDistance > 0,
            let height = groundHeight(position: result.position, radius: controller.radius, distance: snapDistance, minimumNormalY: groundThreshold) {
            // This is a DOWN snap. Its lifted query origin must not ratchet a rounded
            // ledge upward, including while idle after a refused step. Real slopes and
            // accepted steps have already raised result.position through swept motion.
            if height <= result.position.y + 0.006 {
                result.position.y = min(result.position.y, height)
                result.grounded = true
            }
        }
        position = result.position
        controller.velocity = (position - start) / deltaTime
        controller.isGrounded = result.grounded && controller.verticalVelocity <= 0 && !jumped
        if controller.isGrounded { controller.verticalVelocity = 0 }
        if controller.verticalVelocity > 0 && result.ceiling { controller.verticalVelocity = 0 }
        // Collision corrections must not inject energy into the next commanded movement.
        let horizontal = Vector3(controller.velocity.x, 0, controller.velocity.z)
        let maximumSpeed = controller.horizontalVelocity.length
        controller.horizontalVelocity = horizontal.length > maximumSpeed ? horizontal.normalized * maximumSpeed : horizontal
    }

    @MainActor
    private func resolveCharacterHeight(_ controller: inout CharacterController3DComponent, position: Vector3) {
        let requested = controller.requestedHeight
        guard requested.isFinite, (requested * requested).isFinite, requested >= controller.radius * 2 else {
            controller.heightChangeBlocked = true
            return
        }
        if requested == controller.height { return }
        if requested < controller.height {
            controller.height = requested
            controller.heightChangeBlocked = false
            return
        }
        // Same radius and bottom make every intermediate capsule a subset of this candidate.
        // Full overlap catches thin ceilings even when the capsule axis crosses the geometry;
        // CollideMover's contact planes deliberately omit some such deep intersections.
        let clear = characterCapsuleIsClear(position: position, radius: controller.radius, height: requested)
        controller.heightChangeBlocked = !clear
        if clear { controller.height = requested }
    }

    @MainActor
    private func characterCapsuleIsClear(position: Vector3, radius: Float, height: Float, stepping: Bool = false) -> Bool {
        unsafe withUnsafeTemporaryAllocation(of: b3Vec3.self, capacity: 2) { points in
            // Existing support casts allow 5 mm contact slop. Stay below the mover's 15 mm skin;
            // lift the upper query center by the inset so requested head height remains fully checked.
            let inset = min(Float(0.006), radius * 0.05)
            unsafe points[0] = Vector3(0, radius, 0).b3Vec
            unsafe points[1] = Vector3(0, height - radius + inset, 0).b3Vec
            var origin = position
            var queryRadius = radius - inset
            if stepping {
                // Step sweeps must not start laterally overlapped: CastMover ignores initial
                // overlap. Lift the FULL radius/height query by support slop instead of
                // shrinking its sides. Ten mm clears the solver's 5 mm slop on rounded
                // walkable contacts too; it remains below the mover's existing 15 mm skin.
                // The complete head is conservatively checked ten mm higher.
                unsafe points[1] = Vector3(0, height - radius, 0).b3Vec
                queryRadius = radius
                origin.y += 0.01
            }
            var proxy = unsafe b3ShapeProxy(points: points.baseAddress, count: 2, radius: queryRadius)
            var blocked = false
            let filter = unsafe b3DefaultQueryFilter()
            unsafe withUnsafeMutablePointer(to: &blocked) { context in
                _ = unsafe b3World_OverlapShape(worldId, origin.b3Vec, &proxy, filter, noteCharacterHeightOverlap, context)
            }
            return !blocked
        }
    }

    @MainActor
    private func stepCharacter(
        position: Vector3, radius: Float, height: Float, delta: Vector3, slide: Vector3, snapDistance: Float, groundThreshold: Float
    ) -> Vector3? {
        let direction = delta.normalized
        let progress = (slide - position).dot(direction)
        guard progress < delta.length - 0.00001, characterCapsuleIsClear(position: position, radius: radius, height: height, stepping: true) else { return nil }
        let limit = height * 0.05
        var support = position.y
        if let floor = raycast(from: position + Vector3(0, radius, 0), to: position - Vector3(0, snapDistance + 0.006, 0)), floor.normal.y >= groundThreshold {
            support = max(support, floor.position.y + radius * (1 / floor.normal.y - 1))
        }
        var capsule = b3Capsule(center1: Vector3(0, radius, 0).b3Vec, center2: Vector3(0, height - radius, 0).b3Vec, radius: radius)
        let filter = unsafe b3DefaultQueryFilter()
        let up = Vector3(0, limit, 0)
        let upFraction = unsafe b3World_CastMover(worldId, position.b3Vec, &capsule, up.b3Vec, filter, { shape, _ in !b3Shape_IsSensor(shape) }, nil)
        let lift = max(0, limit * upFraction - (upFraction < 1 ? 0.01 : 0))
        let raised = position + Vector3(0, lift, 0)
        guard lift > 0.00001, characterCapsuleIsClear(position: raised, radius: radius, height: height, stepping: true) else { return nil }
        let forward = unsafe b3World_CastMover(worldId, raised.b3Vec, &capsule, delta.b3Vec, filter, { shape, _ in !b3Shape_IsSensor(shape) }, nil)
        // CastMover permits support slop. Stop outside a forward obstacle so a tangent
        // wall is clear for the following full-radius overlap/downward queries.
        let travel = max(0, delta.length * forward - (forward < 1 ? 0.006 : 0))
        let advanced = raised + direction * travel
        guard (advanced - position).dot(direction) > progress + 0.00001 else { return nil }
        var landing = CharacterLanding()
        let down = Vector3(0, -lift - snapDistance, 0)
        unsafe withUnsafeTemporaryAllocation(of: b3Vec3.self, capacity: 2) { points in
            unsafe points[0] = capsule.center1
            unsafe points[1] = capsule.center2
            var proxy = unsafe b3ShapeProxy(points: points.baseAddress, count: 2, radius: radius)
            unsafe withUnsafeMutablePointer(to: &landing) { context in
                _ = unsafe b3World_CastShape(worldId, advanced.b3Vec, &proxy, down.b3Vec, filter, noteCharacterLanding, context)
            }
        }
        let candidate = advanced + down * landing.fraction
        // Measure the surface against true support, compensating the solver's resting
        // penetration without enlarging the physical step budget. 0.1 mm is Float/query tolerance.
        guard landing.fraction <= 1, landing.normal.y >= groundThreshold,
            landing.point.y <= support + limit + 0.0001, candidate.y <= position.y + limit + 0.0001,
            candidate.y >= position.y - snapDistance - 0.006,
            characterCapsuleIsClear(position: candidate, radius: radius, height: height, stepping: true) else { return nil }
        return candidate
    }

    private func moveCapsule(
        position: Vector3, radius: Float, height: Float, delta: Vector3, groundThreshold: Float, blockCorners: Bool
    ) -> (position: Vector3, grounded: Bool, ceiling: Bool) {
        let skin: Float = 0.015
        var capsule = b3Capsule(center1: Vector3(0, radius, 0).b3Vec, center2: Vector3(0, height - radius, 0).b3Vec, radius: radius)
        var queryCapsule = capsule
        queryCapsule.radius += skin
        let filter = unsafe b3DefaultQueryFilter()
        return unsafe withUnsafeTemporaryAllocation(of: b3CollisionPlane.self, capacity: 64) { storage in
            var planes = unsafe CharacterPlanes(storage: storage, skin: skin, blockCorners: blockCorners)
            var current = position
            var remaining = delta
            for _ in 0..<8 {
                unsafe planes.count = 0
                unsafe planes.origin = current
                unsafe planes.horizontalMotion = Vector3(remaining.x, 0, remaining.z)
                unsafe withUnsafeMutablePointer(to: &planes) { pointer in
                    unsafe b3World_CollideMover(worldId, current.b3Vec, &queryCapsule, filter, collectCharacterPlanes, pointer)
                }
                let solved = unsafe b3SolvePlanes(remaining.b3Vec, storage.baseAddress, Int32(planes.count)).delta.asVector3
                if solved.length < 0.00001 { break }
                let fraction = unsafe b3World_CastMover(worldId, current.b3Vec, &capsule, solved.b3Vec, filter, { shape, _ in !b3Shape_IsSensor(shape) }, nil)
                let moved = solved * fraction
                current += moved
                remaining = solved - moved
                if fraction >= 1 { break }
            }
            // Resolve overlap and classify contacts at the final position, including an idle capsule.
            unsafe planes.count = 0
            unsafe planes.origin = current
            unsafe planes.horizontalMotion = Vector3(delta.x, 0, delta.z)
            unsafe withUnsafeMutablePointer(to: &planes) { pointer in
                unsafe b3World_CollideMover(worldId, current.b3Vec, &queryCapsule, filter, collectCharacterPlanes, pointer)
            }
            unsafe current += b3SolvePlanes(Vector3.zero.b3Vec, storage.baseAddress, Int32(planes.count)).delta.asVector3
            var grounded = false
            var ceiling = false
            for index in 0..<(unsafe planes.count) {
                let plane = unsafe storage[index].plane
                if plane.offset >= -skin {
                    grounded = grounded || plane.normal.y >= groundThreshold
                    ceiling = ceiling || plane.normal.y < -0.1
                }
            }
            return (current, grounded, ceiling)
        }
    }
}
