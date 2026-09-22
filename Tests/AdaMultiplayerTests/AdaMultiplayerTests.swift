import AdaApp
import AdaECS
@testable import AdaMultiplayer
import Foundation
import Testing

@Component
private struct TestPosition: Codable, Equatable, Sendable {
    var x: Int
}

@Component
private struct LocalOnlyState: Codable, Equatable, Sendable {
    var secret: Int
}

@ReplicatedComponent(id: "tests.generated-position")
private struct GeneratedPosition: Equatable {
    @NetworkField(1, mode: .latest)
    var x: Int

    @LocalOnly
    var secret = 0
}

@ReplicatedComponent(id: "tests.public-generated-position")
public struct PublicGeneratedPosition {
    @NetworkField(1)
    public var x: Int

    public init(x: Int) {
        self.x = x
    }
}

@NetworkCommand(
    id: "tests.generated-move",
    delivery: .unreliableSequenced,
    channel: "input"
)
private struct GeneratedMoveCommand: Equatable {
    @NetworkField(1)
    var x: Int
}

private struct MoveCommand: NetworkCommand, Equatable {
    static let networkIdentifier = "tests.move"
    var x: Int
}

private struct PingRequest: NetworkRequest {
    static let networkIdentifier = "tests.ping"
    typealias Response = String
    var value: String
}

private struct CapturedCommands: Resource {
    var values: [MoveCommand] = []
    var generatedValues: [GeneratedMoveCommand] = []
}

@PlainSystem
struct CaptureCommandsSystem {
    @RemoteCommands<MoveCommand>
    private var commands

    @RemoteCommands<GeneratedMoveCommand>
    private var generatedCommands

    @ResMut<CapturedCommands>
    private var captured

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        captured.values.append(contentsOf: commands.map(\.value))
        captured.generatedValues.append(contentsOf: generatedCommands.map(\.value))
    }
}

@PlainSystem
struct RespondToPingSystem {
    @RemoteRequests<PingRequest>
    private var requests

    init(world _: World) {}

    func update(context _: UpdateContext) async {
        for request in requests {
            try? await request.responder.respond("pong:" + request.value.value)
        }
    }
}

private struct TestNetworkingPlugin: Plugin {
    func setup(in app: borrowing AppWorlds) {
        app
            .registerReplicatedComponent(TestPosition.self, id: "tests.position")
            .registerReplicatedComponent(GeneratedPosition.self)
            .registerNetworkCommand(MoveCommand.self)
            .registerNetworkCommand(GeneratedMoveCommand.self)
            .registerNetworkRequest(PingRequest.self)
            .insertResource(CapturedCommands())
            .addSystem(CaptureCommandsSystem.self, on: .update)
            .addSystem(RespondToPingSystem.self, on: .update)
    }
}

@Suite("AdaMultiplayer")
@MainActor
struct AdaMultiplayerTests {
    @Test("binary envelope rejects invalid data")
    func wireEnvelope() throws {
        let original = NetworkFrame(kind: .event, sequence: 42, payload: Data([1, 2, 3]))
        let encoded = try NetworkWireCodec.encode(original)
        let decoded = try NetworkWireCodec.decode(encoded)

        #expect(decoded.kind == .event)
        #expect(decoded.sequence == 42)
        #expect(decoded.payload == Data([1, 2, 3]))
        #expect(throws: MultiplayerError.invalidPayload) {
            try NetworkWireCodec.decode(Data([0, 1, 2]))
        }
    }

    @Test("cloud relay routing uses scalar UUID fields")
    func cloudRelayWireShape() throws {
        let session = UUID()
        let peer = UUID()
        let hello = CloudRelayHello(
            ticket: "ticket",
            sessionID: session,
            peerID: peer,
            role: .peer
        )
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any]
        )
        #expect(object["sessionID"] as? String == session.uuidString)
        #expect(object["peerID"] as? String == peer.uuidString)

        let control = try JSONDecoder().decode(
            CloudRelayControl.self,
            from: Data("{\"kind\":\"connected\",\"peerID\":\"\(peer.uuidString)\"}".utf8)
        )
        #expect(control.peerID == peer)
    }

    @Test("peer can only route traffic through host")
    func transportTopology() async throws {
        let hub = InMemoryTransportHub()
        let hostID = PeerID()
        let peerID = PeerID()
        let sessionID = SessionID()
        let host = InMemoryTransport(hub: hub)
        let peer = InMemoryTransport(hub: hub)
        let hostEvents = await host.eventStream()

        try await host.start(configuration: .init(role: .host, sessionID: sessionID, localPeerID: hostID))
        try await peer.start(configuration: .init(role: .peer, sessionID: sessionID, localPeerID: peerID))
        try await peer.send(Data([7]), to: .host)

        var iterator = hostEvents.makeAsyncIterator()
        #expect(await iterator.next().isConnected(to: peerID))
        #expect(await iterator.next().isPayload(Data([7]), source: peerID))
        await #expect(throws: MultiplayerError.invalidDirection) {
            try await peer.send(Data(), to: .allPeers)
        }
    }

    @Test("marker replicates only registered components")
    func markerReplication() async throws {
        let hub = InMemoryTransportHub()
        let sessionID = SessionID()
        let compatibility = NetworkCompatibility(
            gameIdentifier: "tests",
            buildIdentifier: "1"
        )
        let host = try await makeApp(
            role: .host,
            sessionID: sessionID,
            compatibility: compatibility,
            transport: InMemoryTransport(hub: hub)
        )
        let peer = try await makeApp(
            role: .peer,
            sessionID: sessionID,
            compatibility: compatibility,
            transport: InMemoryTransport(hub: hub)
        )

        await exchangeHandshake(host: host, peer: peer)
        host.main.spawn("Player") {
            ReplicatedEntity()
            TestPosition(x: 10)
            LocalOnlyState(secret: 42)
        }
        await host.main.runScheduler(.networkSend)
        await peer.main.runScheduler(.networkReceive)

        let entities = Array(peer.main.performQuery(EntityQuery(where: .has(TestPosition.self))))
        let replica = try #require(entities.first)
        #expect(replica.name == "Player")
        #expect(peer.main.get(TestPosition.self, from: replica.id) == TestPosition(x: 10))
        #expect(peer.main.get(LocalOnlyState.self, from: replica.id) == nil)
    }

    @Test("generated component implies marker and excludes local state")
    func generatedComponentReplication() async throws {
        let (host, peer) = try await makeConnectedApps()
        let entity = host.main.spawn("Generated") {
            GeneratedPosition(x: 17, secret: 42)
        }

        #expect(host.main.has(ReplicatedEntity.self, in: entity.id))
        await sendSnapshot(host: host, peer: peer)

        let replica = try #require(
            Array(peer.main.performQuery(EntityQuery(where: .has(GeneratedPosition.self)))).first
        )
        #expect(peer.main.get(GeneratedPosition.self, from: replica.id) == GeneratedPosition(x: 17))

        let schema = GeneratedPosition.networkDescriptor
        #expect(schema.typeID == "tests.generated-position")
        #expect(schema.fields == [
            NetworkFieldDescriptor(
                tag: 1,
                wireType: .signedInteger,
                replication: .latest
            ),
        ])

        let encoded = try JSONEncoder().encode(GeneratedPosition(x: 17, secret: 42))
        let encodedObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Int])
        #expect(encodedObject == ["1": 17])
        #expect(PublicGeneratedPosition.networkDescriptor.fields.map(\.tag) == [1])
    }

    @Test("delta covers update, removal, and despawn")
    func deltaLifecycle() async throws {
        let (host, peer) = try await makeConnectedApps()
        let entity = host.main.spawn("Player") {
            ReplicatedEntity()
            TestPosition(x: 1)
        }
        await sendSnapshot(host: host, peer: peer)
        let replica = try #require(
            Array(peer.main.performQuery(EntityQuery(where: .has(TestPosition.self)))).first
        )

        host.main.insert(TestPosition(x: 2), for: entity.id)
        await sendSnapshot(host: host, peer: peer)
        #expect(peer.main.get(TestPosition.self, from: replica.id) == TestPosition(x: 2))

        host.main.remove(TestPosition.self, from: entity.id)
        await sendSnapshot(host: host, peer: peer)
        #expect(peer.main.get(TestPosition.self, from: replica.id) == nil)

        host.main.removeEntity(entity)
        await sendSnapshot(host: host, peer: peer)
        #expect(peer.main.getEntityByID(replica.id) == nil)
    }

    @Test("typed command and request response use the host")
    func rpcRoundTrip() async throws {
        let (host, peer) = try await makeConnectedApps()
        let peerSession = try #require(peer.main.getResource(MultiplayerSession.self))

        try await peerSession.sendCommand(MoveCommand(x: 9))
        await host.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.update)
        #expect(host.main.getResource(CapturedCommands.self)?.values == [MoveCommand(x: 9)])

        let response = Task { try await peerSession.request(PingRequest(value: "hello")) }
        try await Task.sleep(for: .milliseconds(10))
        await host.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.update)
        try await Task.sleep(for: .milliseconds(10))
        await peer.main.runScheduler(.networkReceive)
        #expect(try await response.value == "pong:hello")
    }

    @Test("generated command routes typed field-tagged payload")
    func generatedCommandRoundTrip() async throws {
        let (host, peer) = try await makeConnectedApps()
        let peerSession = try #require(peer.main.getResource(MultiplayerSession.self))

        try await peerSession.sendCommand(GeneratedMoveCommand(x: 27))
        await host.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.update)

        #expect(host.main.getResource(CapturedCommands.self)?.generatedValues == [GeneratedMoveCommand(x: 27)])
        #expect(GeneratedMoveCommand.networkIdentifier == "tests.generated-move")
        #expect(GeneratedMoveCommand.networkDescriptor.delivery == .unreliableSequenced)
        #expect(GeneratedMoveCommand.networkDescriptor.channel == "input")

        let encoded = try JSONEncoder().encode(GeneratedMoveCommand(x: 27))
        let encodedObject = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Int])
        #expect(encodedObject == ["1": 27])
    }

    @Test("AdaScript bridge routes detached commands and authoritative snapshots")
    func adaScriptBridgeRoundTrip() async throws {
        let hub = InMemoryTransportHub()
        let sessionID = SessionID()
        let hostID = PeerID()
        let peerID = PeerID()
        let compatibility = NetworkCompatibility(gameIdentifier: "script-tests", buildIdentifier: "1")
        let host = try await makeScriptBridgeApp(
            configuration: MultiplayerConfiguration(
                role: .host,
                sessionID: sessionID,
                localPeerID: hostID,
                compatibility: compatibility
            ),
            transport: InMemoryTransport(hub: hub)
        )
        let peer = try await makeScriptBridgeApp(
            configuration: MultiplayerConfiguration(
                role: .peer,
                sessionID: sessionID,
                localPeerID: peerID,
                compatibility: compatibility
            ),
            transport: InMemoryTransport(hub: hub)
        )
        await exchangeHandshake(host: host, peer: peer)

        peer.main.getRefResource(AdaScriptMultiplayerState.self).wrappedValue.outgoingCommand = [
            .double(0.75), .double(-0.25), .int(3),
        ]
        peer.main.getRefResource(AdaScriptMultiplayerState.self).wrappedValue.outgoingCommandSequence = 1
        await peer.main.runScheduler(.networkSend)
        await host.main.runScheduler(.networkReceive)

        let commands = host.main.getResource(AdaScriptMultiplayerState.self)?.receivedCommands
        #expect(commands == [
            .array([
                .string(peerID.rawValue.uuidString),
                .int(1),
                .array([.double(0.75), .double(-0.25), .int(3)]),
            ]),
        ])

        host.main.getRefResource(AdaScriptMultiplayerState.self).wrappedValue.publishedSnapshot = [
            .string(peerID.rawValue.uuidString), .double(12), .double(8), .int(2),
        ]
        host.main.getRefResource(AdaScriptMultiplayerState.self).wrappedValue.publishedSnapshotSequence = 1
        await host.main.runScheduler(.networkSend)
        await peer.main.runScheduler(.networkReceive)

        #expect(peer.main.getResource(AdaScriptMultiplayerState.self)?.receivedSnapshot == [
            .string(peerID.rawValue.uuidString), .double(12), .double(8), .int(2),
        ])
    }

    private func makeApp(
        role: NetworkRole,
        sessionID: SessionID,
        compatibility: NetworkCompatibility,
        transport: any MultiplayerTransport
    ) async throws -> AppWorlds {
        let app = AppWorlds(main: World(name: role.rawValue))
        app
            .addPlugin(
                MultiplayerPlugin(
                    configuration: MultiplayerConfiguration(
                        role: role,
                        sessionID: sessionID,
                        compatibility: compatibility,
                        snapshotsPerSecond: 1_000
                    ),
                    transport: transport
                )
            )
            .addPlugin(TestNetworkingPlugin())
        try await app.build()
        return app
    }

    private func makeScriptBridgeApp(
        configuration: MultiplayerConfiguration,
        transport: any MultiplayerTransport
    ) async throws -> AppWorlds {
        let app = AppWorlds(main: World(name: configuration.role.rawValue))
        app
            .addPlugin(MultiplayerPlugin(configuration: configuration, transport: transport))
            .addPlugin(AdaScriptMultiplayerBridgePlugin(configuration: configuration))
        try await app.build()
        return app
    }

    private func exchangeHandshake(host: AppWorlds, peer: AppWorlds) async {
        await host.main.runScheduler(.networkReceive)
        await peer.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.networkReceive)
        await peer.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.networkReceive)
    }

    private func makeConnectedApps() async throws -> (AppWorlds, AppWorlds) {
        let hub = InMemoryTransportHub()
        let sessionID = SessionID()
        let compatibility = NetworkCompatibility(gameIdentifier: "tests", buildIdentifier: "1")
        let host = try await makeApp(
            role: .host,
            sessionID: sessionID,
            compatibility: compatibility,
            transport: InMemoryTransport(hub: hub)
        )
        let peer = try await makeApp(
            role: .peer,
            sessionID: sessionID,
            compatibility: compatibility,
            transport: InMemoryTransport(hub: hub)
        )
        await exchangeHandshake(host: host, peer: peer)
        return (host, peer)
    }

    private func sendSnapshot(host: AppWorlds, peer: AppWorlds) async {
        try? await Task.sleep(for: .milliseconds(2))
        await host.main.runScheduler(.networkSend)
        await peer.main.runScheduler(.networkReceive)
        await peer.main.runScheduler(.networkInterpolate)
    }
}

private extension MultiplayerTransportEvent? {
    func isConnected(to peer: PeerID) -> Bool {
        guard case let .connected(value) = self else {
            return false
        }
        return value == peer
    }

    func isPayload(_ payload: Data, source: PeerID) -> Bool {
        guard case let .received(valueSource, valuePayload) = self else {
            return false
        }
        return valueSource == source && valuePayload == payload
    }
}
