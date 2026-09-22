import AdaApp
import AdaECS
import Foundation

/// Installs transport-independent multiplayer replication and RPC systems.
public struct MultiplayerPlugin: Plugin {
    private let configuration: MultiplayerConfiguration
    private let transport: any MultiplayerTransport
    private let codec: any NetworkCodec
    private let replicationPolicy: any ReplicationPolicy

    public init(
        configuration: MultiplayerConfiguration,
        transport: any MultiplayerTransport,
        codec: any NetworkCodec = JSONNetworkCodec(),
        replicationPolicy: any ReplicationPolicy = AllPeersReplicationPolicy()
    ) {
        self.configuration = configuration
        self.transport = transport
        self.codec = codec
        self.replicationPolicy = replicationPolicy
    }

    public func setup(in app: borrowing AppWorlds) {
        ReplicatedEntity.registerComponent()
        NetworkOwner.registerComponent()

        var registry = MultiplayerRegistry()
        registry.registerBuiltInComponents()

        app
            .insertResource(registry)
            .insertResource(
                MultiplayerRuntime(
                    configuration: configuration,
                    codec: codec,
                    replicationPolicy: replicationPolicy
                )
            )
            .insertResource(
                MultiplayerSession(configuration: configuration, transport: transport)
            )
            .addSystem(NetworkReceiveSystem.self, on: .networkReceive)
            .addSystem(NetworkSendSystem.self, on: .networkSend)
            .addSystem(NetworkInterpolationSystem.self, on: .networkInterpolate)
    }
}

@propertyWrapper
final class MultiplayerWorldAccess: @unchecked Sendable {
    var wrappedValue: MultiplayerWorldAccess { self }

    static var access: SystemAccessSet {
        var access = SystemAccessSet()
        // Network systems perform type-erased structural mutation. Making this
        // access exclusive prevents concurrent world queries while those
        // descriptors are applied.
        access.addDeferredWorldAccess()
        return access
    }

    init() {}
}

extension MultiplayerWorldAccess: SystemParameter {
    convenience init(from _: World) {
        self.init()
    }

    func update(from _: World) {}
}

struct HostEntityState: Sendable {
    var localID: Entity.ID
    var name: String
    var components: [String: Data]
}

struct InterpolationKey: Hashable, Sendable {
    var entity: NetworkEntityID
    var component: String
}

struct InterpolationSample: Sendable {
    var previous: Data
    var current: Data
    var receivedAt: TimeInterval
}

struct MultiplayerRuntime: Resource {
    var configuration: MultiplayerConfiguration
    var codec: any NetworkCodec
    var replicationPolicy: any ReplicationPolicy
    var sequence: UInt64 = 0
    var lastReceivedSequence: UInt64 = 0
    var simulationTick: UInt64 = 0
    var lastSnapshotAt: TimeInterval = 0
    var compatiblePeers: Set<PeerID> = []
    var peersNeedingBaseline: Set<PeerID> = []
    var hostEntities: [NetworkEntityID: HostEntityState] = [:]
    var clientEntities: [NetworkEntityID: Entity.ID] = [:]
    var clientPayloads: [InterpolationKey: Data] = [:]
    var interpolationSamples: [InterpolationKey: InterpolationSample] = [:]

    init(
        configuration: MultiplayerConfiguration,
        codec: any NetworkCodec,
        replicationPolicy: any ReplicationPolicy
    ) {
        self.configuration = configuration
        self.codec = codec
        self.replicationPolicy = replicationPolicy
    }

    func effectiveCompatibility(registry: MultiplayerRegistry) -> NetworkCompatibility {
        var compatibility = configuration.compatibility
        if compatibility.schemaDigest.isEmpty {
            compatibility.schemaDigest = registry.schemaDigest
        }
        return compatibility
    }
}

@PlainSystem
struct NetworkReceiveSystem {
    @Res<MultiplayerSession>
    private var session

    @Res<MultiplayerRegistry>
    private var registry

    @ResMut<MultiplayerRuntime>
    private var runtime

    @MultiplayerWorldAccess
    private var worldAccess

    init(world _: World) {}

    func update(context: UpdateContext) async {
        _ = worldAccess
        await session.ensureStarted()

        for descriptor in registry.rpcByTypeID.values {
            descriptor.clear(context.world)
        }

        let events = await session.drainTransportEvents()
        for event in events {
            do {
                switch event {
                case let .connected(peer):
                    await session.markConnected(peer)
                    try await sendHandshake(to: peer)
                case let .disconnected(peer):
                    runtime.compatiblePeers.remove(peer)
                    runtime.peersNeedingBaseline.remove(peer)
                    await session.markDisconnected(peer)
                case let .received(source, payload):
                    try await receive(payload, source: source, world: context.world)
                case let .failed(message):
                    await session.end(.transportFailure(message))
                }
            } catch {
                await session.end(.transportFailure(String(describing: error)))
            }
        }
    }

    private func sendHandshake(to peer: PeerID) async throws {
        let handshake = NetworkHandshake(
            compatibility: runtime.effectiveCompatibility(registry: registry),
            role: runtime.configuration.role,
            sessionID: runtime.configuration.sessionID,
            peerID: runtime.configuration.localPeerID
        )
        try await session.send(
            frame: NetworkFrame(
                kind: .handshake,
                payload: try runtime.codec.encode(handshake)
            ),
            to: runtime.configuration.role == .host ? .peer(peer) : .host
        )
    }

    private func receive(_ bytes: Data, source: PeerID, world: World) async throws {
        let frame = try NetworkWireCodec.decode(bytes)
        switch frame.kind {
        case .handshake:
            try await receiveHandshake(frame, source: source)
        case .handshakeAccepted:
            runtime.compatiblePeers.insert(source)
            if runtime.configuration.role == .host {
                runtime.peersNeedingBaseline.insert(source)
            }
        case .snapshot:
            guard runtime.configuration.role == .peer, runtime.compatiblePeers.contains(source) else {
                throw MultiplayerError.invalidDirection
            }
            let snapshot = try runtime.codec.decode(NetworkSnapshot.self, from: frame.payload)
            try apply(snapshot, sequence: frame.sequence, world: world)
        case .command, .event, .request:
            try receiveRPC(frame, source: source, world: world)
        case .response:
            guard let correlationID = frame.correlationID else {
                throw MultiplayerError.invalidPayload
            }
            await session.resolveResponse(correlationID, payload: frame.payload)
        case .protocolError:
            let failure = try runtime.codec.decode(NetworkProtocolFailure.self, from: frame.payload)
            await session.end(.transportFailure("\(failure.code): \(failure.message)"))
        }
    }

    private func receiveHandshake(_ frame: NetworkFrame, source: PeerID) async throws {
        let handshake = try runtime.codec.decode(NetworkHandshake.self, from: frame.payload)
        let expected = runtime.effectiveCompatibility(registry: registry)
        guard handshake.sessionID == runtime.configuration.sessionID,
            handshake.compatibility.protocolMajor == expected.protocolMajor,
            handshake.compatibility.gameIdentifier == expected.gameIdentifier,
            handshake.compatibility.buildIdentifier == expected.buildIdentifier
        else {
            try await reject(source, error: .incompatibleProtocol)
            return
        }
        guard handshake.compatibility.schemaDigest == expected.schemaDigest else {
            try await reject(source, error: .incompatibleSchema)
            return
        }
        guard handshake.role != runtime.configuration.role else {
            try await reject(source, error: .invalidDirection)
            return
        }

        runtime.compatiblePeers.insert(source)
        if runtime.configuration.role == .host {
            runtime.peersNeedingBaseline.insert(source)
        }
        try await session.send(
            frame: NetworkFrame(kind: .handshakeAccepted, payload: Data()),
            to: runtime.configuration.role == .host ? .peer(source) : .host
        )
    }

    private func reject(_ peer: PeerID, error: MultiplayerError) async throws {
        let failure = NetworkProtocolFailure(
            code: String(describing: error),
            message: "Multiplayer compatibility check failed"
        )
        try await session.send(
            frame: NetworkFrame(kind: .protocolError, payload: try runtime.codec.encode(failure)),
            to: runtime.configuration.role == .host ? .peer(peer) : .host
        )
        await session.end(.incompatiblePeer(peer))
    }

    private func receiveRPC(_ frame: NetworkFrame, source: PeerID, world: World) throws {
        guard runtime.compatiblePeers.contains(source),
            let typeID = frame.typeID,
            let version = frame.typeVersion,
            let descriptor = registry.rpcByTypeID[typeID],
            descriptor.version == version,
            frame.payload.count <= descriptor.maximumPayloadSize
        else {
            throw MultiplayerError.unknownMessage(frame.typeID ?? "")
        }

        let expectedKind: RPCMessageKind = switch frame.kind {
        case .command: .command
        case .event: .event
        case .request: .request
        default: throw MultiplayerError.invalidPayload
        }
        guard descriptor.kind == expectedKind else {
            throw MultiplayerError.invalidPayload
        }

        let allowed = switch (runtime.configuration.role, descriptor.direction) {
        case (.host, .peerToHost), (.peer, .hostToPeer), (_, .bidirectional): true
        default: false
        }
        guard allowed else {
            throw MultiplayerError.invalidDirection
        }
        try descriptor.deliver(
            source,
            frame.correlationID,
            frame.payload,
            world,
            session,
            runtime.codec
        )
    }

    private func apply(_ snapshot: NetworkSnapshot, sequence: UInt64, world: World) throws {
        guard sequence > runtime.lastReceivedSequence else {
            return
        }
        runtime.lastReceivedSequence = sequence

        let receivedIDs = Set(snapshot.entities.lazy.filter { !$0.despawned }.map(\.id))
        if snapshot.baseline {
            for (networkID, localID) in runtime.clientEntities where !receivedIDs.contains(networkID) {
                world.removeEntity(localID)
                runtime.clientEntities[networkID] = nil
            }
        }

        for entityDelta in snapshot.entities {
            if entityDelta.despawned {
                if let localID = runtime.clientEntities.removeValue(forKey: entityDelta.id) {
                    world.removeEntity(localID)
                }
                continue
            }

            let localID: Entity.ID
            if let existing = runtime.clientEntities[entityDelta.id] {
                localID = existing
            } else {
                let entity = world.spawn(entityDelta.name)
                world.insert(ReplicatedEntity(id: entityDelta.id), for: entity.id)
                runtime.clientEntities[entityDelta.id] = entity.id
                localID = entity.id
            }

            for componentDelta in entityDelta.components {
                guard let descriptor = registry.replicatedComponentsByTypeID[componentDelta.typeID],
                    descriptor.version == componentDelta.version
                else {
                    throw MultiplayerError.unknownMessage(componentDelta.typeID)
                }
                let key = InterpolationKey(entity: entityDelta.id, component: componentDelta.typeID)
                switch componentDelta.operation {
                case .remove:
                    descriptor.remove(world, localID)
                    runtime.clientPayloads[key] = nil
                    runtime.interpolationSamples[key] = nil
                case .set:
                    guard let payload = componentDelta.payload else {
                        throw MultiplayerError.invalidPayload
                    }
                    if descriptor.interpolate != nil, let previous = runtime.clientPayloads[key] {
                        runtime.interpolationSamples[key] = InterpolationSample(
                            previous: previous,
                            current: payload,
                            receivedAt: Date.timeIntervalSinceReferenceDate
                        )
                    } else {
                        try descriptor.apply(payload, world, localID, runtime.codec)
                    }
                    runtime.clientPayloads[key] = payload
                }
            }
        }
    }
}

@PlainSystem
struct NetworkSendSystem {
    @Res<MultiplayerSession>
    private var session

    @Res<MultiplayerRegistry>
    private var registry

    @ResMut<MultiplayerRuntime>
    private var runtime

    @MultiplayerWorldAccess
    private var worldAccess

    init(world _: World) {}

    func update(context: UpdateContext) async {
        _ = worldAccess
        guard runtime.configuration.role == .host else {
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        guard now - runtime.lastSnapshotAt >= 1 / runtime.configuration.snapshotsPerSecond else {
            return
        }
        runtime.lastSnapshotAt = now
        runtime.simulationTick &+= 1

        do {
            let current = try capture(world: context.world)
            for peer in runtime.peersNeedingBaseline where runtime.compatiblePeers.contains(peer) {
                let snapshot = makeBaseline(from: current, for: peer)
                try await send(snapshot, to: .peer(peer))
                runtime.peersNeedingBaseline.remove(peer)
            }
            let delta = makeDelta(previous: runtime.hostEntities, current: current)
            if !delta.entities.isEmpty {
                for peer in runtime.compatiblePeers {
                    let visible = NetworkSnapshot(
                        baseline: false,
                        entities: delta.entities.filter {
                            runtime.replicationPolicy.shouldReplicate(entity: $0.id, to: peer)
                        }
                    )
                    if !visible.entities.isEmpty {
                        try await send(visible, to: .peer(peer))
                    }
                }
            }
            runtime.hostEntities = current
        } catch {
            await session.end(.transportFailure(String(describing: error)))
        }
    }

    private func capture(world: World) throws -> [NetworkEntityID: HostEntityState] {
        var result: [NetworkEntityID: HostEntityState] = [:]
        let query = EntityQuery(where: .has(ReplicatedEntity.self))
        for entity in world.performQuery(query) {
            guard var marker = world.get(ReplicatedEntity.self, from: entity.id) else {
                continue
            }
            if marker.id == nil {
                marker.id = NetworkEntityID()
                world.insert(marker, for: entity.id)
            }
            guard let networkID = marker.id else {
                continue
            }
            var components: [String: Data] = [:]
            for descriptor in registry.replicatedComponentsByTypeID.values {
                if let payload = try descriptor.encode(world, entity.id, runtime.codec) {
                    components[descriptor.typeID] = payload
                }
            }
            result[networkID] = HostEntityState(
                localID: entity.id,
                name: entity.name,
                components: components
            )
        }
        return result
    }

    private func makeBaseline(
        from current: [NetworkEntityID: HostEntityState],
        for peer: PeerID
    ) -> NetworkSnapshot {
        NetworkSnapshot(
            baseline: true,
            entities: current.compactMap { id, state in
                guard runtime.replicationPolicy.shouldReplicate(entity: id, to: peer) else {
                    return nil
                }
                return NetworkEntityDelta(
                    id: id,
                    name: state.name,
                    despawned: false,
                    components: componentSets(state.components)
                )
            }
        )
    }

    private func makeDelta(
        previous: [NetworkEntityID: HostEntityState],
        current: [NetworkEntityID: HostEntityState]
    ) -> NetworkSnapshot {
        var entities: [NetworkEntityDelta] = []
        for (id, state) in current {
            guard let old = previous[id] else {
                entities.append(
                    NetworkEntityDelta(
                        id: id,
                        name: state.name,
                        despawned: false,
                        components: componentSets(state.components)
                    )
                )
                continue
            }
            var changes: [NetworkComponentDelta] = []
            for (typeID, payload) in state.components where old.components[typeID] != payload {
                guard let descriptor = registry.replicatedComponentsByTypeID[typeID] else {
                    continue
                }
                changes.append(
                    NetworkComponentDelta(
                        typeID: typeID,
                        version: descriptor.version,
                        operation: .set,
                        payload: payload
                    )
                )
            }
            for typeID in old.components.keys where state.components[typeID] == nil {
                guard let descriptor = registry.replicatedComponentsByTypeID[typeID] else {
                    continue
                }
                changes.append(
                    NetworkComponentDelta(
                        typeID: typeID,
                        version: descriptor.version,
                        operation: .remove,
                        payload: nil
                    )
                )
            }
            if !changes.isEmpty {
                entities.append(
                    NetworkEntityDelta(id: id, name: state.name, despawned: false, components: changes)
                )
            }
        }
        for (id, state) in previous where current[id] == nil {
            entities.append(
                NetworkEntityDelta(id: id, name: state.name, despawned: true, components: [])
            )
        }
        return NetworkSnapshot(baseline: false, entities: entities)
    }

    private func componentSets(_ components: [String: Data]) -> [NetworkComponentDelta] {
        components.compactMap { typeID, payload in
            guard let descriptor = registry.replicatedComponentsByTypeID[typeID] else {
                return nil
            }
            return NetworkComponentDelta(
                typeID: typeID,
                version: descriptor.version,
                operation: .set,
                payload: payload
            )
        }
    }

    private func send(_ snapshot: NetworkSnapshot, to target: NetworkTarget) async throws {
        runtime.sequence &+= 1
        try await session.send(
            frame: NetworkFrame(
                kind: .snapshot,
                sequence: runtime.sequence,
                simulationTick: runtime.simulationTick,
                payload: try runtime.codec.encode(snapshot)
            ),
            to: target
        )
    }
}

@PlainSystem
struct NetworkInterpolationSystem {
    @Res<MultiplayerRegistry>
    private var registry

    @ResMut<MultiplayerRuntime>
    private var runtime

    @MultiplayerWorldAccess
    private var worldAccess

    init(world _: World) {}

    func update(context: UpdateContext) async {
        _ = worldAccess
        guard runtime.configuration.role == .peer else {
            return
        }
        let now = Date.timeIntervalSinceReferenceDate
        let duration = 1 / runtime.configuration.snapshotsPerSecond
        for (key, sample) in runtime.interpolationSamples {
            guard let localID = runtime.clientEntities[key.entity],
                let descriptor = registry.replicatedComponentsByTypeID[key.component],
                let interpolate = descriptor.interpolate
            else {
                runtime.interpolationSamples[key] = nil
                continue
            }
            let alpha = Float(min(1, max(0, (now - sample.receivedAt) / duration)))
            do {
                let payload = try interpolate(sample.previous, sample.current, alpha, runtime.codec)
                try descriptor.apply(payload, context.world, localID, runtime.codec)
                if alpha >= 1 {
                    runtime.interpolationSamples[key] = nil
                }
            } catch {
                runtime.interpolationSamples[key] = nil
            }
        }
    }
}
