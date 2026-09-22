import AdaEngine
import AdaMultiplayer
import Foundation
import Math

@PlainSystem
struct ArenaConnectionSystem {
    @Query<Entity, NetworkOwner>
    private var owners

    @Res<MultiplayerSession>
    private var session

    @Res<ArenaRuntime>
    private var runtime

    @Commands
    private var commands

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        guard runtime.role == .host else {
            return
        }

        var existing: [PeerID: Entity.ID] = [:]
        owners.forEach { entity, owner in
            existing[owner.peer] = entity.id
        }
        let remotePeers = await session.peers()
        let activePeers = remotePeers.union([runtime.localPeerID])
        let orderedPeers = activePeers.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }
        let remoteOrder = remotePeers.sorted { $0.rawValue.uuidString < $1.rawValue.uuidString }

        for peer in orderedPeers where existing[peer] == nil {
            let variant = peer == runtime.localPeerID
                ? 0
                : 1 + (remoteOrder.firstIndex(of: peer) ?? 0)
            commands.spawn(peer == runtime.localPeerID ? "Host knight" : "Peer knight") {
                Transform(position: ArenaRules.spawnPosition(for: variant))
                ReplicatedEntity(id: NetworkEntityID(rawValue: peer.rawValue))
                NetworkOwner(peer: peer)
                ArenaPlayerState(
                    displayName: peer == runtime.localPeerID ? "HOST" : "PEER \(variant)",
                    facing: peer == runtime.localPeerID ? .right : .left,
                    variant: variant
                )
            }
            runtime.diagnostics.record("spawned player \(peer.rawValue.uuidString) variant=\(variant)")
        }

        for (peer, entity) in existing where peer != runtime.localPeerID && !remotePeers.contains(peer) {
            commands.entity(entity).removeFromWorld(recursively: true)
            runtime.diagnostics.record("removed disconnected player \(peer.rawValue.uuidString)")
        }
    }
}

@PlainSystem(dependencies: [.after(ScriptComponentUpdateSystem.self)])
struct ArenaBotInputSystem {
    @Res<ArenaRuntime>
    private var runtime

    @ResMut<ArenaInputState>
    private var input

    @Res<ElapsedTime>
    private var elapsed

    @Local
    private var lastAttackBucket = -1

    init(world _: World) {}

    func update(context _: UpdateContext) {
        guard runtime.runsBot else {
            return
        }
        input.moveX = elapsed.elapsedTime < 0.35 ? -1 : 0
        input.moveY = 0
        let bucket = Int(elapsed.elapsedTime / 0.65)
        if bucket > lastAttackBucket {
            lastAttackBucket = bucket
            input.attackSequence += 1
        }
    }
}

@PlainSystem(dependencies: [.after(ArenaBotInputSystem.self)])
struct ArenaPeerInputSystem {
    @Res<MultiplayerSession>
    private var session

    @Res<ArenaRuntime>
    private var runtime

    @Res<ArenaInputState>
    private var input

    @Local
    private var connectedFrames = 0

    @Local
    private var didLogSend = false

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        guard runtime.role == .peer else {
            return
        }
        guard await session.currentState() == .connected else {
            connectedFrames = 0
            return
        }
        connectedFrames += 1
        guard connectedFrames >= 8 else {
            return
        }
        do {
            try await session.sendCommand(
                ArenaInputCommand(
                    moveX: input.moveX,
                    moveY: input.moveY,
                    attackSequence: input.attackSequence
                )
            )
            if !didLogSend {
                didLogSend = true
                runtime.diagnostics.record("sent first input attack=\(input.attackSequence)")
            }
        } catch MultiplayerError.notConnected {
            connectedFrames = 0
        } catch {
            runtime.diagnostics.record("input send failed: \(error)")
        }
    }
}

@PlainSystem(dependencies: [.after(ArenaBotInputSystem.self)])
struct ArenaHostGameplaySystem {
    private struct Attack {
        var attacker: Entity.ID
        var position: Vector3
        var facing: ArenaFacing
    }

    @Query<Entity, Ref<ArenaPlayerState>, NetworkOwner, Ref<Transform>>
    private var players

    @RemoteCommands<ArenaInputCommand>
    private var remoteCommands

    @Res<ArenaRuntime>
    private var runtime

    @Res<ArenaInputState>
    private var localInput

    @Res<DeltaTime>
    private var deltaTime

    @Local
    private var didLogRemoteInput = false

    init(world _: World) {}

    func update(context _: UpdateContext) {
        guard runtime.role == .host else {
            return
        }

        var inputs: [PeerID: ArenaInputCommand] = [:]
        for remote in remoteCommands {
            inputs[remote.source] = remote.value
        }
        if !remoteCommands.isEmpty, !didLogRemoteInput {
            didLogRemoteInput = true
            runtime.diagnostics.record("received first remote input")
        }
        inputs[runtime.localPeerID] = ArenaInputCommand(
            moveX: localInput.moveX,
            moveY: localInput.moveY,
            attackSequence: localInput.attackSequence
        )

        var attacks: [Attack] = []
        players.forEach { entity, state, owner, transform in
            if state.health <= 0 {
                state.respawnRemaining = max(0, state.respawnRemaining - deltaTime.deltaTime)
                if state.respawnRemaining <= 0 {
                    state.health = 3
                    transform.position = ArenaRules.spawnPosition(for: state.variant)
                    runtime.diagnostics.record("respawned \(state.displayName)")
                }
                return
            }
            guard let input = inputs[owner.peer] else {
                return
            }

            var moveX = max(-1, min(1, input.moveX))
            var moveY = max(-1, min(1, input.moveY))
            let lengthSquared = moveX * moveX + moveY * moveY
            if lengthSquared > 1 {
                let inverseLength = 1 / sqrt(lengthSquared)
                moveX *= inverseLength
                moveY *= inverseLength
            }
            transform.position.x = max(
                -ArenaRules.halfWidth,
                min(ArenaRules.halfWidth, transform.position.x + moveX * ArenaRules.movementSpeed * deltaTime.deltaTime)
            )
            transform.position.y = max(
                -ArenaRules.halfHeight,
                min(ArenaRules.halfHeight, transform.position.y + moveY * ArenaRules.movementSpeed * deltaTime.deltaTime)
            )
            if abs(moveX) > abs(moveY), abs(moveX) > 0.01 {
                state.facing = moveX < 0 ? .left : .right
            } else if abs(moveY) > 0.01 {
                state.facing = moveY < 0 ? .down : .up
            }

            if input.attackSequence > state.lastAttackInputSequence {
                state.lastAttackInputSequence = input.attackSequence
                state.attackSequence += 1
                attacks.append(Attack(attacker: entity.id, position: transform.position, facing: state.facing))
            }
        }

        var snapshots: [(entity: Entity.ID, position: Vector3, health: Int)] = []
        players.forEach { entity, state, _, transform in
            snapshots.append((entity.id, transform.position, state.health))
        }
        var damage: [Entity.ID: Int] = [:]
        for attack in attacks {
            if let target = snapshots.first(where: {
                $0.entity != attack.attacker
                    && $0.health > 0
                    && ArenaRules.isHit(attacker: attack.position, facing: attack.facing, target: $0.position)
            }) {
                damage[target.entity, default: 0] += 1
            }
        }

        players.forEach { entity, state, _, _ in
            guard let amount = damage[entity.id], state.health > 0 else {
                return
            }
            state.health = max(0, state.health - amount)
            runtime.diagnostics.record("damage target=\(state.displayName) health=\(state.health)")
            if state.health == 0 {
                state.respawnRemaining = ArenaRules.respawnDelay
                runtime.diagnostics.record("defeated \(state.displayName)")
            }
        }
    }
}
