import AdaECS
import Math

/// An upright capsule mover. Its entity's position is the bottom of the capsule in world units.
/// Use on a root entity without `PhysicsBody3DComponent`; visual scale does not resize the capsule.
/// The controller collides with physics bodies, ignores sensors, and does not push dynamic bodies
/// or register a body that other character controllers can collide with.
@Component
public struct CharacterController3DComponent: Sendable {
    public let radius: Float
    public let height: Float

    /// Requested world-space horizontal velocity. The Y component is ignored.
    public var desiredVelocity: Vector3 = .zero
    /// Acceleration and braking in meters per second squared.
    public var acceleration: Float = 14
    public var deceleration: Float = 20
    public var jumpSpeed: Float = 5
    /// Set on a press edge. Consumed by the next fixed tick, including while airborne.
    public var jumpRequested = false
    public var maximumFallSpeed: Float = 50
    /// Minimum upward surface normal for grounded contacts; defaults to a 45 degree slope.
    public var minimumGroundNormalY: Float = 0.707107

    public internal(set) var isGrounded = false
    /// Actual displacement per second after collision resolution.
    public internal(set) var velocity: Vector3 = .zero
    internal var horizontalVelocity: Vector3 = .zero
    internal var verticalVelocity: Float = 0

    /// Invalid dimensions fall back to a 0.4 meter radius and a height of at least two radii.
    public init(radius: Float = 0.4, height: Float = 1.8) {
        self.radius = radius.isFinite && radius > 0 ? radius : 0.4
        self.height = height.isFinite ? max(height, self.radius * 2) : max(1.8, self.radius * 2)
    }
}
