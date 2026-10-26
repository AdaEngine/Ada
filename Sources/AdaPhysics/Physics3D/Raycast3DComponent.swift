import AdaECS
import Math

/// A script-friendly asynchronous query against real 3D collision geometry.
/// Increment requestID after setting endpoints; completedRequestID identifies
/// the returned result. Results are transient and never decoded from a scene.
@Component
public struct Raycast3DComponent: Codable, Sendable {
    public var origin: Vector3 = .zero
    public var destination: Vector3 = [0, 0, 1]
    public var excludingEntityID: Int = -1
    public var includeSensors: Bool = false
    public var requestID: Int = 0
    public internal(set) var completedRequestID: Int = -1
    public internal(set) var hasHit: Bool = false
    public internal(set) var hitEntityID: Int = -1
    public internal(set) var hitPosition: Vector3 = .zero
    public internal(set) var hitNormal: Vector3 = .zero
    public internal(set) var hitDistance: Float = 0
    public internal(set) var errorCode: String = ""

    public init() {}

    private enum CodingKeys: CodingKey { case origin, destination, excludingEntityID, includeSensors, requestID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        origin = try values.decodeIfPresent(Vector3.self, forKey: .origin) ?? .zero
        destination = try values.decodeIfPresent(Vector3.self, forKey: .destination) ?? [0, 0, 1]
        excludingEntityID = try values.decodeIfPresent(Int.self, forKey: .excludingEntityID) ?? -1
        includeSensors = try values.decodeIfPresent(Bool.self, forKey: .includeSensors) ?? false
        requestID = try values.decodeIfPresent(Int.self, forKey: .requestID) ?? 0
    }
}

@PlainSystem(dependencies: [.after(Physics3DWritebackSystem.self), .after(CharacterController3DSystem.self)])
public struct Raycast3DSystem {
    @Query<Ref<Raycast3DComponent>> private var rays
    @ResMut<Physics3DWorldHolder> private var physics

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        rays.forEach { query in
            guard query.requestID != query.completedRequestID else { return }
            query.completedRequestID = query.requestID
            query.hasHit = false
            query.hitEntityID = -1
            query.hitPosition = query.destination
            query.hitNormal = .zero
            query.hitDistance = 0
            query.errorCode = ""
            guard validRaySegment3D(query.origin, query.destination) else {
                query.errorCode = "invalidRay"
                return
            }
            let ignored = query.excludingEntityID >= 0 ? query.excludingEntityID : nil
            guard let hit = physics.world.raycast(from: query.origin, to: query.destination,
                excluding: ignored, includeSensors: query.includeSensors) else { return }
            query.hasHit = true
            query.hitEntityID = hit.entityID ?? -1
            query.hitPosition = hit.position
            query.hitNormal = hit.normal
            query.hitDistance = hit.distance
        }
    }
}
