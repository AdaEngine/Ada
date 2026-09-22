import AdaEngine
import AdaMultiplayer
import Foundation
import Math

public enum ArenaResources {
    public static var bundle: Bundle { .module }
}

public enum ArenaFacing: String, Codable, Sendable {
    case up
    case down
    case left
    case right

    var vector: Vector2 {
        switch self {
        case .up: [0, 1]
        case .down: [0, -1]
        case .left: [-1, 0]
        case .right: [1, 0]
        }
    }
}

@Component
public struct ArenaPlayerState: Codable, Sendable {
    public var displayName: String
    public var health: Int
    public var facing: ArenaFacing
    public var attackSequence: Int
    public var lastAttackInputSequence: Int
    public var respawnRemaining: Float
    public var variant: Int

    public init(
        displayName: String,
        health: Int = 3,
        facing: ArenaFacing = .down,
        attackSequence: Int = 0,
        lastAttackInputSequence: Int = 0,
        respawnRemaining: Float = 0,
        variant: Int = 0
    ) {
        self.displayName = displayName
        self.health = health
        self.facing = facing
        self.attackSequence = attackSequence
        self.lastAttackInputSequence = lastAttackInputSequence
        self.respawnRemaining = respawnRemaining
        self.variant = variant
    }
}

public struct ArenaInputCommand: NetworkCommand {
    public static let networkIdentifier = "medieval-arena.input"

    public var moveX: Float
    public var moveY: Float
    public var attackSequence: Int

    public init(moveX: Float, moveY: Float, attackSequence: Int) {
        self.moveX = moveX
        self.moveY = moveY
        self.attackSequence = attackSequence
    }
}

public struct ArenaInputState: Resource, Sendable {
    public var moveX: Float = 0
    public var moveY: Float = 0
    public var attackSequence: Int = 0

    public init() {}

    @MainActor
    public static func registerRuntimeType() {
        RuntimeTypeRegistry.registerResource(Self.self, names: ["ArenaInputState", "medieval-arena.input-state"])
        RuntimeResourceReflectionRegistry.register(Self.self, fields: ["moveX", "moveY", "attackSequence"].map { key in
            unsafe ReflectedComponentField(
                key: key,
                label: key,
                kind: key == "attackSequence" ? .int : .float,
                isWritable: true,
                read: { _ in nil },
                write: { _, _ in nil },
                readPointer: { pointer in
                    let value = unsafe pointer.assumingMemoryBound(to: Self.self).pointee
                    switch key {
                    case "moveX": return .double(Double(value.moveX))
                    case "moveY": return .double(Double(value.moveY))
                    default: return .int(value.attackSequence)
                    }
                },
                writePointer: { pointer, field in
                    let value = unsafe pointer.assumingMemoryBound(to: Self.self)
                    switch key {
                    case "moveX": return unsafe ComponentReflection.write(field, to: &value.pointee.moveX)
                    case "moveY": return unsafe ComponentReflection.write(field, to: &value.pointee.moveY)
                    default: return unsafe ComponentReflection.write(field, to: &value.pointee.attackSequence)
                    }
                }
            )
        })
    }
}

struct ArenaRuntime: Resource {
    var role: NetworkRole
    var localPeerID: PeerID
    var runsBot: Bool
    var diagnostics: ArenaDiagnostics
}

struct ArenaTextures: Resource {
    var floor: AssetHandle<Texture2D>
    var wall: AssetHandle<Texture2D>
    var players: [AssetHandle<Texture2D>]
    var sword: AssetHandle<Texture2D>
}

struct ArenaPresentationState: Resource {
    var lastAttackByPlayer: [NetworkEntityID: Int] = [:]
}

@Component
struct ArenaHeartVisual {
    var owner: NetworkEntityID
    var heartIndex: Int
    var part: Int
}

@Component
struct ArenaSwordEffect {
    var remaining: Float
}

@Component
struct ArenaStatusLabel {}

@Component
struct ArenaHintLabel {}

enum ArenaRules {
    static let halfWidth: Float = 410
    static let halfHeight: Float = 220
    static let movementSpeed: Float = 175
    static let attackReach: Float = 62
    static let respawnDelay: Float = 2

    static func spawnPosition(for variant: Int) -> Vector3 {
        let slots: [Vector3] = [
            [-25, 0, 2],
            [25, 0, 2],
            [0, 100, 2],
            [0, -100, 2],
            [-180, 90, 2],
            [180, -90, 2]
        ]
        return slots[variant % slots.count]
    }

    static func isHit(attacker: Vector3, facing: ArenaFacing, target: Vector3) -> Bool {
        let dx = target.x - attacker.x
        let dy = target.y - attacker.y
        let distanceSquared = dx * dx + dy * dy
        guard distanceSquared <= attackReach * attackReach, distanceSquared > 0.01 else {
            return false
        }
        let direction = facing.vector
        let length = sqrt(distanceSquared)
        return (dx / length) * direction.x + (dy / length) * direction.y > 0.45
    }
}
