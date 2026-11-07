import AdaECS
import AdaPhysics
import AdaTransform
import Math

struct TerrainPhysicsInterest: Equatable, Sendable {
    let min: Vector2
    let max: Vector2
}

struct TerrainPhysicsInterests: Equatable, Sendable {
    static let maximumCount = 64
    let rectangles: [TerrainPhysicsInterest]
    let requiresAllRegions: Bool

    init(rectangles: [TerrainPhysicsInterest] = [], requiresAllRegions: Bool = false) {
        self.rectangles = rectangles
        self.requiresAllRegions = requiresAllRegions
    }

    var isEmpty: Bool { rectangles.isEmpty && !requiresAllRegions }

    /// Nil means the bounded collector overflowed; conservatively request all declared terrain.
    static func project(_ worldBounds: [AABB]?, inverse: Transform3D) -> Self {
        guard let worldBounds else {
            return .init(requiresAllRegions: true)
        }
        var rectangles: [TerrainPhysicsInterest] = []
        for bounds in worldBounds {
            guard let local = transform(bounds, by: inverse) else {
                return .init(requiresAllRegions: true)
            }
            rectangles.append(.init(min: [local.min.x, local.min.z], max: [local.max.x, local.max.z]))
        }
        rectangles.sort { left, right in
            if left.min.x != right.min.x {
                return left.min.x < right.min.x
            }
            if left.min.y != right.min.y {
                return left.min.y < right.min.y
            }
            if left.max.x != right.max.x {
                return left.max.x < right.max.x
            }
            return left.max.y < right.max.y
        }
        return .init(rectangles: rectangles)
    }

    static func transform(_ bounds: AABB, by matrix: Transform3D) -> AABB? {
        let lower = bounds.min, upper = bounds.max
        var minimum = Vector3(Float.infinity, Float.infinity, Float.infinity)
        var maximum = -minimum
        for corner in 0..<8 {
            let point = Vector3(
                corner & 1 == 0 ? lower.x : upper.x,
                corner & 2 == 0 ? lower.y : upper.y,
                corner & 4 == 0 ? lower.z : upper.z
            )
            let value = (matrix * Vector4(point, 1)).xyz
            guard finite(value) else {
                return nil
            }
            minimum = min(minimum, value)
            maximum = max(maximum, value)
        }
        let value = AABB(min: minimum, max: maximum)
        return finite(value.center) && finite(value.halfExtents) ? value : nil
    }

    static func swept(_ bounds: AABB, first: Vector3, second: Vector3, duration: Float) -> AABB? {
        guard finite(bounds.min), finite(bounds.max), finite(first), finite(second), duration.isFinite else {
            return nil
        }
        let firstOffset = first * duration, secondOffset = second * duration
        let minimum = min(bounds.min, min(bounds.min + firstOffset, bounds.min + secondOffset))
        let maximum = max(bounds.max, max(bounds.max + firstOffset, bounds.max + secondOffset))
        let value = AABB(min: minimum, max: maximum)
        return finite(value.center) && finite(value.halfExtents) ? value : nil
    }

    private static func finite(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
}

struct TerrainSourceFocus: Equatable, Sendable {
    let cameras: [Vector3]
    let allCameraRegions: Bool
    let physics: TerrainPhysicsInterests
}

enum TerrainPhysicsBounds {
    static func collect(
        bodies: Query<Entity, PhysicsBody3DComponent, Transform>,
        characters: FilterQuery<Entity, CharacterController3DComponent, Transform, Without<PhysicsBody3DComponent>>,
        physics: Physics3DWorldHolder?,
        deltaTime: Float
    ) -> [AABB]? {
        guard let physics else {
            return []
        }
        guard deltaTime.isFinite, deltaTime >= 0 else {
            return nil
        }
        let duration = max(0.25, deltaTime)
        let gravity = physics.world.gravity
        var bounds: Set<AABB> = []
        var overflow = false
        func append(_ value: AABB?) {
            guard let value else {
                overflow = true
                return
            }
            if !bounds.contains(value) {
                if bounds.count == TerrainPhysicsInterests.maximumCount { overflow = true } else { bounds.insert(value) }
            }
        }
        bodies.forEach { _, body, transform in
            switch body.currentSimulationMode {
            case .static: return
            case .dynamic, .kinematic: break
            }
            var worldBounds: AABB
            if let current = body.worldBounds {
                worldBounds = current
            } else {
                let pose = Transform(rotation: transform.rotation, position: transform.position).matrix
                guard let initial = TerrainPhysicsInterests.transform(body.localBounds ?? .empty, by: pose) else {
                    append(nil)
                    return
                }
                worldBounds = initial
            }
            if body.angularVelocity != .zero {
                let radius = worldBounds.halfExtents.length * 3
                worldBounds = AABB(center: worldBounds.center, halfExtents: Vector3(radius, radius, radius))
            }
            let velocity = body.linearVelocity
            let accelerated = velocity + gravity * (body.gravityScale * duration)
            append(TerrainPhysicsInterests.swept(worldBounds, first: velocity, second: accelerated, duration: duration))
        }
        characters.forEach { _, character, transform in
            let radius = character.radius
            let capsule = AABB(
                min: transform.position + Vector3(-radius, 0, -radius),
                max: transform.position + Vector3(radius, max(character.height, character.requestedHeight), radius)
            )
            let falling = Vector3(character.desiredVelocity.x, -abs(character.maximumFallSpeed), character.desiredVelocity.z)
            append(TerrainPhysicsInterests.swept(capsule, first: character.velocity, second: falling, duration: duration))
        }
        return overflow ? nil : Array(bounds)
    }
}
