import AdaECS
import Math

/// Deferred oriented-box query against the current native world. Set all inputs,
/// then increment requestID and wait for its matching completedRequestID.
/// Invalid queries fail closed (hasOverlap=true, errorCode=invalidBox).
/// Results are transient and never restored from authored scene data.
@Component
public struct OverlapBox3DComponent: Codable, Sendable {
    public var center: Vector3 = .zero
    public var halfExtents: Vector3 = [0.5, 0.5, 0.5]
    public var rotation: Quat = .identity
    public var excludingEntityID: Int = -1
    public var includeSensors: Bool = false
    public var requestID: Int = 0
    public internal(set) var completedRequestID: Int = -1
    public internal(set) var hasOverlap: Bool = true
    public internal(set) var hitEntityID: Int = -1
    public internal(set) var errorCode: String = ""

    public init() {}

    private enum CodingKeys: CodingKey { case center, halfExtents, rotation, excludingEntityID, includeSensors, requestID }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        center = try values.decodeIfPresent(Vector3.self, forKey: .center) ?? .zero
        halfExtents = try values.decodeIfPresent(Vector3.self, forKey: .halfExtents) ?? [0.5, 0.5, 0.5]
        rotation = try values.decodeIfPresent(Quat.self, forKey: .rotation) ?? .identity
        excludingEntityID = try values.decodeIfPresent(Int.self, forKey: .excludingEntityID) ?? -1
        includeSensors = try values.decodeIfPresent(Bool.self, forKey: .includeSensors) ?? false
        requestID = try values.decodeIfPresent(Int.self, forKey: .requestID) ?? 0
    }
}

@PlainSystem(dependencies: [.after(Physics3DWritebackSystem.self), .after(CharacterController3DSystem.self)])
public struct OverlapBox3DSystem {
    @Query<Ref<OverlapBox3DComponent>> private var boxes
    @ResMut<Physics3DWorldHolder> private var physics

    public init(world _: World) {}

    @MainActor
    public func update(context _: UpdateContext) {
        boxes.forEach { query in
            guard query.requestID != query.completedRequestID else { return }
            query.completedRequestID = query.requestID
            query.hasOverlap = true
            query.hitEntityID = -1
            query.errorCode = ""
            let ignored = query.excludingEntityID >= 0 ? query.excludingEntityID : nil
            guard let result = physics.world.overlapBox(center: query.center, halfExtents: query.halfExtents,
                rotation: query.rotation, excluding: ignored, includeSensors: query.includeSensors) else {
                query.errorCode = "invalidBox"
                return
            }
            query.hasOverlap = result.hasOverlap
            query.hitEntityID = result.entityID ?? -1
        }
    }
}
