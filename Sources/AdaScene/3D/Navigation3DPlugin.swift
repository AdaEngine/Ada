import AdaApp
import AdaAssets
import AdaECS
import AdaNavigation
import AdaPhysics
import AdaTransform
import Foundation
import Math

/// Opt-in path following for root entities with a CharacterController3DComponent.
/// Install Physics3DPlugin as well. Add a map and target components for automatic requests.
public struct Navigation3DPlugin: Plugin {
    public init() {}

    public func setup(in app: AppWorlds) {
        AssetsManager.registerAssetType(NavigationMeshAsset.self)
        NavigationMap3DSource.registerComponent()
        app.addSystem(NavigationMap3DSourceSystem.self, on: .preUpdate)
        RuntimeTypeRegistry.registerComponent(
            NavigationAgent3DComponent.self,
            names: ["NavigationAgent3DComponent", String(reflecting: NavigationAgent3DComponent.self)],
            makeDefault: { NavigationAgent3DComponent() }
        )
        RuntimeTypeRegistry.registerComponent(
            NavigationTarget3DComponent.self,
            names: ["NavigationTarget3DComponent", String(reflecting: NavigationTarget3DComponent.self)],
            makeDefault: { NavigationTarget3DComponent() }
        )
        app.addSystem(NavigationPathRequest3DSystem.self, on: .update)
        app.addSystem(NavigationAgent3DSystem.self, on: .physicsWriteback)
    }
}

/// Runtime route state; replace the follower's path after a new navigation query.
@Component
public struct NavigationAgent3DComponent: Codable, Sendable {
    public var follower: NavigationPathFollower
    public internal(set) var lastError: NavigationError?
    /// Minimum interval between retries for a blocked or unreachable target.
    public var repathInterval: Float = 0.5
    /// A moving goal must move this far to trigger another query while following.
    public var targetRepathDistance: Float = 0.25
    var elapsedSinceRequest: Float = 0
    var lastRequestedTarget: Vector3?
    var mapRevision: UUID?
    var requestSerial: UInt64 = 0

    /// Stable script-facing state: idle, following, arrived, partialEnd, blocked or failed.
    public var state: String { lastError == nil ? String(describing: follower.state) : "failed" }
    /// Empty when there is no failure; otherwise the corresponding NavigationError case name.
    public var errorCode: String { lastError.map { String(describing: $0) } ?? "" }
    public var hasArrived: Bool { lastError == nil && follower.state == .arrived }
    public var hasPath: Bool { follower.path != nil }
    public var pathPointCount: Int { follower.path?.points.count ?? 0 }
    public var routeLength: Float { follower.path?.length ?? 0 }
    /// Maximum requested speed in world units per second.
    public var maximumSpeed: Float {
        get { follower.maximumSpeed }
        set { follower.maximumSpeed = newValue }
    }
    public var arrivalTolerance: Float {
        get { follower.arrivalTolerance }
        set { follower.arrivalTolerance = newValue }
    }

    @AdaScriptInit
    public init(follower: NavigationPathFollower = NavigationPathFollower()) {
        self.follower = follower
    }
}

extension NavigationAgent3DComponent {
    private enum CodingKeys: CodingKey { case maximumSpeed, arrivalTolerance, repathInterval, targetRepathDistance }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        maximumSpeed = try values.decodeIfPresent(Float.self, forKey: .maximumSpeed) ?? maximumSpeed
        arrivalTolerance = try values.decodeIfPresent(Float.self, forKey: .arrivalTolerance) ?? arrivalTolerance
        repathInterval = try values.decodeIfPresent(Float.self, forKey: .repathInterval) ?? repathInterval
        targetRepathDistance = try values.decodeIfPresent(Float.self, forKey: .targetRepathDistance) ?? targetRepathDistance
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(maximumSpeed, forKey: .maximumSpeed)
        try values.encode(arrivalTolerance, forKey: .arrivalTolerance)
        try values.encode(repathInterval, forKey: .repathInterval)
        try values.encode(targetRepathDistance, forKey: .targetRepathDistance)
    }
}

/// Produces input before the existing controller resolves collisions and changes Transform.
@PlainSystem(dependencies: [.after(Physics3DWritebackSystem.self), .before(CharacterController3DSystem.self)])
public struct NavigationAgent3DSystem {
    @FilterQuery<Ref<NavigationAgent3DComponent>, Ref<CharacterController3DComponent>, Transform, Without<PhysicsBody3DComponent>>
    private var agents

    @Res<FixedTime?> private var time

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        guard let time else { return }
        agents.forEach { agent, controller, transform in
            do throws(NavigationError) {
                agent.follower.brakingAcceleration = controller.deceleration
                controller.desiredVelocity = try agent.follower.update(position: transform.position, deltaTime: time.deltaTime)
                // An idle follower returns zero successfully even after a failed path query.
                // Preserve that failure so automatic requests retain their retry interval.
                if agent.follower.path != nil { agent.lastError = nil }
            } catch let error {
                controller.desiredVelocity = .zero
                agent.lastError = error
            }
        }
    }
}
