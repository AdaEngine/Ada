import AdaECS
import Math

/// An upright capsule mover. Its entity's position is the bottom of the capsule in world units.
/// Use on a root entity without `PhysicsBody3DComponent`; visual scale does not resize the capsule.
/// The controller collides with physics bodies, ignores sensors, and does not push dynamic bodies
/// or register a body that other character controllers can collide with.
/// Supported walking automatically steps over solid ledges up to 5% of the resolved height,
/// provided the full capsule can sweep up, forward, and down to a walkable landing.
@Component
public struct CharacterController3DComponent: Codable, Sendable {
    public let radius: Float
    /// Actual resolved capsule height. Runtime requests never move the feet to make room.
    public internal(set) var height: Float
    /// Height requested for the next fixed move. Must have finite geometry dimensions and be at least twice the radius.
    /// Shrinking is immediate; growth waits for solid-body clearance and retries while requested.
    /// Invalid requests retain the previous valid target, so nonfinite commands cannot enter saved state.
    public var requestedHeight: Float {
        didSet {
            guard requestedHeight.isFinite, (requestedHeight * requestedHeight).isFinite, requestedHeight >= radius * 2 else {
                requestedHeight = oldValue
                heightChangeBlocked = true
                return
            }
            if requestedHeight != oldValue || requestedHeight == height { heightChangeBlocked = false }
        }
    }
    /// The most recent request was invalid or could not fit. Sensors do not block resizing.
    public internal(set) var heightChangeBlocked: Bool = false

    /// Requested world-space horizontal velocity. The Y component is ignored.
    public var desiredVelocity: Vector3 = .zero
    /// Acceleration and braking in meters per second squared.
    public var acceleration: Float = 14
    public var deceleration: Float = 20
    /// Fraction of ground acceleration/braking available in air. Zero preserves takeoff momentum.
    /// Defaults to one for compatibility with existing arcade controllers.
    public var airControl: Float = 1
    public var jumpSpeed: Float = 5
    /// Set on a press edge. Consumed by the next fixed tick, including while airborne.
    public var jumpRequested: Bool = false
    /// Clears accumulated motion on the next fixed tick after a scripted teleport.
    public var resetMotion: Bool = false
    public var maximumFallSpeed: Float = 50
    /// Minimum upward surface normal for grounded contacts; defaults to a 45 degree slope.
    public var minimumGroundNormalY: Float = 0.707107
    /// Follows descending terrain while grounded; disabled automatically during a jump.
    public var groundSnapDistance: Float = 0.16

    public internal(set) var isGrounded: Bool = false
    /// Actual displacement per second after collision resolution.
    public internal(set) var velocity: Vector3 = .zero
    internal var horizontalVelocity: Vector3 = .zero
    internal var verticalVelocity: Float = 0

    /// Invalid dimensions fall back to a 0.4 meter radius and a height of at least two radii.
    public init(radius: Float = 0.4, height: Float = 1.8) {
        self.radius = radius.isFinite && radius > 0 ? radius : 0.4
        self.height = height.isFinite ? max(height, self.radius * 2) : max(1.8, self.radius * 2)
        self.requestedHeight = self.height
    }

    private enum CodingKeys: CodingKey {
        case radius, height, requestedHeight, acceleration, deceleration, airControl, jumpSpeed, maximumFallSpeed, minimumGroundNormalY, groundSnapDistance
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(radius: try values.decodeIfPresent(Float.self, forKey: .radius) ?? 0.4,
                  height: try values.decodeIfPresent(Float.self, forKey: .height) ?? 1.8)
        requestedHeight = try values.decodeIfPresent(Float.self, forKey: .requestedHeight) ?? height
        acceleration = try values.decodeIfPresent(Float.self, forKey: .acceleration) ?? 14
        deceleration = try values.decodeIfPresent(Float.self, forKey: .deceleration) ?? 20
        airControl = try values.decodeIfPresent(Float.self, forKey: .airControl) ?? 1
        jumpSpeed = try values.decodeIfPresent(Float.self, forKey: .jumpSpeed) ?? 5
        maximumFallSpeed = try values.decodeIfPresent(Float.self, forKey: .maximumFallSpeed) ?? 50
        minimumGroundNormalY = try values.decodeIfPresent(Float.self, forKey: .minimumGroundNormalY) ?? 0.707107
        groundSnapDistance = try values.decodeIfPresent(Float.self, forKey: .groundSnapDistance) ?? 0.16
    }
}
