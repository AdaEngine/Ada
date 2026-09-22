import AdaEngine
import AdaMultiplayer
import Foundation
import Math

@PlainSystem
struct ArenaPresentationSystem {
    private struct HeartKey: Hashable {
        var owner: NetworkEntityID
        var index: Int
        var part: Int
    }

    private struct PlayerView {
        var entity: Entity.ID
        var networkID: NetworkEntityID
        var position: Vector3
        var health: Int
        var facing: ArenaFacing
        var attackSequence: Int
        var variant: Int
    }

    @Query<Entity, Ref<ArenaPlayerState>, Ref<Transform>, ReplicatedEntity>
    private var players

    @Query<Entity, ArenaHeartVisual, Ref<Transform>, Ref<Sprite>>
    private var hearts

    @Query<Entity, ArenaPlayerState, Ref<Sprite>>
    private var sprites

    @Res private var textures: ArenaTextures?

    @ResMut<ArenaPresentationState>
    private var presentation

    @Commands
    private var commands

    init(world _: World) {}

    func update(context: UpdateContext) {
        guard let textures else {
            return
        }

        var views: [NetworkEntityID: PlayerView] = [:]
        players.forEach { entity, state, transform, marker in
            guard let networkID = marker.id else {
                return
            }
            let view = PlayerView(
                entity: entity.id,
                networkID: networkID,
                position: transform.position,
                health: state.health,
                facing: state.facing,
                attackSequence: state.attackSequence,
                variant: state.variant
            )
            views[networkID] = view
            if context.world.get(Sprite.self, from: entity.id) == nil {
                let texture = textures.players[state.variant % textures.players.count]
                commands.entity(entity.id).insert(
                    Sprite(
                        texture: texture,
                        flipX: state.facing == .left,
                        size: Size(width: 48, height: 48)
                    )
                )
            }

            if let previousAttack = presentation.lastAttackByPlayer[networkID] {
                if previousAttack != state.attackSequence {
                    spawnSword(for: view, texture: textures.sword)
                }
            }
            presentation.lastAttackByPlayer[networkID] = state.attackSequence
        }

        sprites.forEach { _, state, sprite in
            sprite.flipX = state.facing == .left
            sprite.tintColor = .white.opacity(state.health > 0 ? 1 : 0.28)
        }

        var existingHearts = Set<HeartKey>()
        hearts.forEach { entity, heart, transform, sprite in
            guard let player = views[heart.owner] else {
                commands.entity(entity.id).removeFromWorld()
                return
            }
            let key = HeartKey(owner: heart.owner, index: heart.heartIndex, part: heart.part)
            existingHearts.insert(key)
            transform.position = heartPosition(player: player.position, index: heart.heartIndex, part: heart.part)
            sprite.tintColor = heart.heartIndex < player.health ? .red : .white.opacity(0.22)
        }

        for player in views.values {
            for heartIndex in 0..<3 {
                for part in 0..<3 {
                    let key = HeartKey(owner: player.networkID, index: heartIndex, part: part)
                    guard !existingHearts.contains(key) else {
                        continue
                    }
                    let size = part == 2
                        ? Size(width: 9, height: 9)
                        : Size(width: 7, height: 7)
                    let rotation = part == 2
                        ? Quat(axis: [0, 0, 1], angle: .pi / 4)
                        : Quat.identity
                    commands.spawn("Heart \(heartIndex + 1)") {
                        Transform(
                            rotation: rotation,
                            position: heartPosition(player: player.position, index: heartIndex, part: part)
                        )
                        Sprite(
                            texture: Texture2D.whiteTexture,
                            tintColor: heartIndex < player.health ? .red : .white.opacity(0.22),
                            size: size
                        )
                        ArenaHeartVisual(owner: player.networkID, heartIndex: heartIndex, part: part)
                    }
                }
            }
        }

        for networkID in presentation.lastAttackByPlayer.keys where views[networkID] == nil {
            presentation.lastAttackByPlayer[networkID] = nil
        }
    }

    private func spawnSword(for player: PlayerView, texture: AssetHandle<Texture2D>) {
        let direction = player.facing.vector
        let angle: Float = switch player.facing {
        case .up: 0
        case .right: -.pi / 2
        case .down: .pi
        case .left: .pi / 2
        }
        commands.spawn("Sword swing") {
            Transform(
                rotation: Quat(axis: [0, 0, 1], angle: angle),
                position: [
                    player.position.x + direction.x * 34,
                    player.position.y + direction.y * 34,
                    6
                ]
            )
            Sprite(texture: texture, size: Size(width: 34, height: 34))
            ArenaSwordEffect(remaining: 0.16)
        }
    }

    private func heartPosition(player: Vector3, index: Int, part: Int) -> Vector3 {
        let centerX = player.x + Float(index - 1) * 17
        let offset: Vector2 = switch part {
        case 0: [-3.2, 2]
        case 1: [3.2, 2]
        default: [0, -1.5]
        }
        return [centerX + offset.x, player.y + 37 + offset.y, 7]
    }
}

@PlainSystem
struct ArenaSwordEffectSystem {
    @Query<Entity, Ref<ArenaSwordEffect>, Ref<Sprite>>
    private var effects

    @Res<DeltaTime>
    private var deltaTime

    @Commands
    private var commands

    init(world _: World) {}

    func update(context _: UpdateContext) {
        effects.forEach { entity, effect, sprite in
            effect.remaining -= deltaTime.deltaTime
            sprite.tintColor = .white.opacity(max(0, effect.remaining / 0.16))
            if effect.remaining <= 0 {
                commands.entity(entity.id).removeFromWorld()
            }
        }
    }
}

@PlainSystem
struct ArenaStatusSystem {
    @Query<Ref<TextComponent>, ArenaStatusLabel>
    private var labels

    @Res<MultiplayerSession>
    private var session

    @Res<ArenaRuntime>
    private var runtime

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        let state = await session.currentState()
        let peers = await session.peers().count
        let status: String = switch state {
        case .idle: "IDLE"
        case .connecting: "CONNECTING"
        case .connected: runtime.role == .host ? "HOST • \(peers) PEER(S)" : "PEER • CONNECTED"
        case .ended(let reason): "ENDED • \(String(describing: reason))"
        }
        var attributes = TextAttributeContainer()
        attributes.foregroundColor = state == .connected ? .green : .white
        attributes.font = .system(size: 20)
        labels.forEach { text, _ in
            text.text = AttributedText(status, attributes: attributes)
        }
    }
}
