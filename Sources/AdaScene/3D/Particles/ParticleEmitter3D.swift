import AdaECS
import AdaRender
import AdaTransform
import Math

/// World-space smoke/dust emitter. Existing particles keep their momentum when the emitter moves.
/// Distances are metres, velocities metres/second. Stop emission to let smoke dissipate naturally.
@Component(required: [GlobalTransform.self, Visibility.self])
public struct ParticleEmitter3D: Codable, Sendable {
    public var isEmitting: Bool = true
    public var isPaused: Bool = false
    public var restartCount: Int = 0
    public var maxParticles: Int = 256
    public var emissionRate: Float = 24
    public var burstCount: Int = 0
    /// Increment to add a burst without clearing particles from previous bursts.
    public var burstRequest: Int = 0
    public var duration: Float = 1
    public var loops: Bool = true
    public var lifetime: Float = 4
    public var lifetimeVariation: Float = 1
    public var initialVelocity: Vector3 = [0, 0.8, 0]
    public var velocityVariation: Vector3 = [0.3, 0.2, 0.3]
    public var spawnRadius: Float = 0.12
    /// Nonzero extents select a uniformly filled box instead of a spherical spawn region.
    public var spawnBoxHalfExtents: Vector3 = .zero
    /// 0 soft unlit smoke, 1 falling rain, 2 snow, 3 locally lit layered smoke.
    public var particleStyle: Int = 0
    /// Width divided by length for rain streaks.
    public var aspectRatio: Float = 0.035
    public var collisionPlaneEnabled: Bool = false
    public var collisionPlaneHeight: Float = 0
    /// Buoyancy or gravity in world axes.
    public var acceleration: Vector3 = [0, 0.15, 0]
    public var wind: Vector3 = [0.3, 0, 0]
    /// Velocity approaches wind exponentially; zero disables air resistance.
    public var drag: Float = 0.5
    public var turbulence: Float = 0.25
    public var initialSize: Float = 0.35
    public var expansionRate: Float = 0.45
    public var opacity: Float = 0.3
    public var color: Vector3 = [0.45, 0.47, 0.5]
    /// Intersection fade distance against opaque geometry.
    public var softDistance: Float = 0.25
    public var seed: Int = 1
    var simulation: ParticleSimulation3D?
    var appliedRestartCount = 0
    var appliedBurstRequest = 0

    public var particleCount: Int { simulation?.particleCount ?? 0 }

    @AdaScriptInit
    public init() {}

    private enum CodingKeys: CodingKey {
        case isEmitting, isPaused, restartCount, maxParticles, emissionRate, burstCount, burstRequest, duration, loops
        case lifetime, lifetimeVariation, initialVelocity, velocityVariation, spawnRadius, acceleration, wind
        case drag, turbulence, initialSize, expansionRate, opacity, color, softDistance, seed
        case spawnBoxHalfExtents, particleStyle, aspectRatio, collisionPlaneEnabled, collisionPlaneHeight
    }

    public init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEmitting = try values.decodeIfPresent(Bool.self, forKey: .isEmitting) ?? isEmitting
        isPaused = try values.decodeIfPresent(Bool.self, forKey: .isPaused) ?? isPaused
        restartCount = try values.decodeIfPresent(Int.self, forKey: .restartCount) ?? restartCount
        maxParticles = try values.decodeIfPresent(Int.self, forKey: .maxParticles) ?? maxParticles
        emissionRate = try values.decodeIfPresent(Float.self, forKey: .emissionRate) ?? emissionRate
        burstCount = try values.decodeIfPresent(Int.self, forKey: .burstCount) ?? burstCount
        burstRequest = try values.decodeIfPresent(Int.self, forKey: .burstRequest) ?? burstRequest
        duration = try values.decodeIfPresent(Float.self, forKey: .duration) ?? duration
        loops = try values.decodeIfPresent(Bool.self, forKey: .loops) ?? loops
        lifetime = try values.decodeIfPresent(Float.self, forKey: .lifetime) ?? lifetime
        lifetimeVariation = try values.decodeIfPresent(Float.self, forKey: .lifetimeVariation) ?? lifetimeVariation
        initialVelocity = try Self.vector(values, .initialVelocity, initialVelocity)
        velocityVariation = try Self.vector(values, .velocityVariation, velocityVariation)
        spawnRadius = try values.decodeIfPresent(Float.self, forKey: .spawnRadius) ?? spawnRadius
        spawnBoxHalfExtents = try Self.vector(values, .spawnBoxHalfExtents, spawnBoxHalfExtents)
        particleStyle = try values.decodeIfPresent(Int.self, forKey: .particleStyle) ?? particleStyle
        aspectRatio = try values.decodeIfPresent(Float.self, forKey: .aspectRatio) ?? aspectRatio
        collisionPlaneEnabled = try values.decodeIfPresent(Bool.self, forKey: .collisionPlaneEnabled) ?? collisionPlaneEnabled
        collisionPlaneHeight = try values.decodeIfPresent(Float.self, forKey: .collisionPlaneHeight) ?? collisionPlaneHeight
        acceleration = try Self.vector(values, .acceleration, acceleration)
        wind = try Self.vector(values, .wind, wind)
        drag = try values.decodeIfPresent(Float.self, forKey: .drag) ?? drag
        turbulence = try values.decodeIfPresent(Float.self, forKey: .turbulence) ?? turbulence
        initialSize = try values.decodeIfPresent(Float.self, forKey: .initialSize) ?? initialSize
        expansionRate = try values.decodeIfPresent(Float.self, forKey: .expansionRate) ?? expansionRate
        opacity = try values.decodeIfPresent(Float.self, forKey: .opacity) ?? opacity
        color = try Self.vector(values, .color, color)
        softDistance = try values.decodeIfPresent(Float.self, forKey: .softDistance) ?? softDistance
        seed = try values.decodeIfPresent(Int.self, forKey: .seed) ?? seed
    }

    private static func vector(_ values: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys, _ fallback: Vector3) throws -> Vector3 {
        guard values.contains(key), try !values.decodeNil(forKey: key) else { return fallback }
        if let components = try? values.decode([Float].self, forKey: key), components.count == 3 {
            return Vector3(components[0], components[1], components[2])
        }
        return try values.decode(Vector3.self, forKey: key)
    }
}
