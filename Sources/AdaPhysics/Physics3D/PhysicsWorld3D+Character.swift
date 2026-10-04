import box3d
import Math

// Box3D invokes these callbacks synchronously. Both the context and plane storage are scoped
// to one move and never escape to a task or the physics world.
@unsafe
private struct CharacterPlanes {
    var storage: UnsafeMutableBufferPointer<b3CollisionPlane>
    var count = 0
    var skin: Float
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
        unsafe planes.pointee.storage[planes.pointee.count] = b3CollisionPlane(
            plane: plane, pushLimit: .greatestFiniteMagnitude, push: 0, clipVelocity: true
        )
        unsafe planes.pointee.count += 1
    }
    return true
}

extension PhysicsWorld3D {
    @MainActor
    func moveCharacter(_ controller: inout CharacterController3DComponent, position: inout Vector3, deltaTime: Float) {
        guard deltaTime.isFinite, deltaTime > 0, position.x.isFinite, position.y.isFinite, position.z.isFinite else {
            return
        }
        let desired = controller.desiredVelocity
        guard desired.x.isFinite, desired.z.isFinite else {
            return
        }
        let target = Vector3(desired.x, 0, desired.z)
        guard target.length.isFinite else {
            return
        }
        let rate = target.length > 0.001 ? controller.acceleration : controller.deceleration
        let change = target - controller.horizontalVelocity
        let maxChange = max(0, rate.isFinite ? rate : 0) * deltaTime
        controller.horizontalVelocity += change.length > maxChange && change.length > 0 ? change.normalized * maxChange : change
        let jumped = controller.jumpRequested && controller.isGrounded && controller.jumpSpeed.isFinite && controller.jumpSpeed > 0
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
        var result = moveCapsule(position: start, radius: controller.radius, height: controller.height, delta: velocity * deltaTime, groundThreshold: groundThreshold)
        let snapDistance = controller.groundSnapDistance.isFinite ? min(max(controller.groundSnapDistance, 0), controller.radius) : 0
        if controller.isGrounded, !jumped, controller.verticalVelocity <= 0, snapDistance > 0,
            let height = groundHeight(position: result.position, radius: controller.radius, distance: snapDistance, minimumNormalY: groundThreshold) {
            result.position.y = height
            result.grounded = true
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

    private func moveCapsule(position: Vector3, radius: Float, height: Float, delta: Vector3, groundThreshold: Float) -> (position: Vector3, grounded: Bool, ceiling: Bool) {
        let skin: Float = 0.015
        var capsule = b3Capsule(center1: Vector3(0, radius, 0).b3Vec, center2: Vector3(0, height - radius, 0).b3Vec, radius: radius)
        var queryCapsule = capsule
        queryCapsule.radius += skin
        let filter = unsafe b3DefaultQueryFilter()
        return unsafe withUnsafeTemporaryAllocation(of: b3CollisionPlane.self, capacity: 64) { storage in
            var planes = unsafe CharacterPlanes(storage: storage, skin: skin)
            var current = position
            var remaining = delta
            for _ in 0..<8 {
                unsafe planes.count = 0
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
