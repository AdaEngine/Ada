import AdaApp
import AdaECS
import AdaMultiplayer
import AdaScripting
import Foundation
import Testing

@Suite("Typed AdaScript multiplayer", .serialized)
struct AdaScriptNetworkTests {
    @Test("Rejects a remote binding to an unknown command")
    func rejectsUnknownCommandBinding() {
        #expect(throws: AdaScriptError.invalidManifest(
            "@remote_commands references unknown command 'MissingCommand'"
        )) {
            try AdaScriptPlugin(source: """
            @system class InvalidSystem {
                @remote_commands(MissingCommand) var commands;
                func update(context) {}
            }
            """)
        }
    }

    @Test("Matches the Swift command schema digest")
    @MainActor
    func matchesSwiftSchemaDigest() throws {
        let compatibility = NetworkCompatibility(gameIdentifier: "schema-tests", buildIdentifier: "1")
        let nativeApp = AppWorlds(main: World(name: "Native schema"))
        MultiplayerPlugin(
            configuration: MultiplayerConfiguration(role: .host, compatibility: compatibility),
            transport: InMemoryTransport(hub: InMemoryTransportHub())
        ).setup(in: nativeApp)
        nativeApp.registerNetworkCommand(SwiftCrossLanguageCommand.self)

        let scriptApp = AppWorlds(main: World(name: "AdaScript schema"))
        MultiplayerPlugin(
            configuration: MultiplayerConfiguration(role: .host, compatibility: compatibility),
            transport: InMemoryTransport(hub: InMemoryTransportHub())
        ).setup(in: scriptApp)
        let script = try AdaScriptPlugin(source: """
        @network_command(
            id: "tests.cross-language",
            delivery: "unreliable_sequenced",
            channel: "input"
        )
        struct CrossLanguageCommand {
            @network_field(1) var amount = 0;
        }

        @system class NoopSystem { func update(context) {} }
        """)
        script.setup(in: scriptApp)

        #expect(
            nativeApp.main.getResource(MultiplayerRegistry.self)?.schemaDigest
                == scriptApp.main.getResource(MultiplayerRegistry.self)?.schemaDigest
        )
    }

    @Test("Sends and receives a typed command without a script mailbox")
    @MainActor
    func typedCommandRoundTrip() async throws {
        registerResources()

        let hub = InMemoryTransportHub()
        let sessionID = SessionID()
        let hostID = PeerID()
        let peerID = PeerID()
        let compatibility = NetworkCompatibility(gameIdentifier: "adascript-network-tests", buildIdentifier: "1")
        let host = try await makeApp(
            role: .host,
            sessionID: sessionID,
            peerID: hostID,
            compatibility: compatibility,
            transport: InMemoryTransport(hub: hub),
            shouldSend: false
        )
        let peer = try await makeApp(
            role: .peer,
            sessionID: sessionID,
            peerID: peerID,
            compatibility: compatibility,
            transport: InMemoryTransport(hub: hub),
            shouldSend: true
        )
        await exchangeHandshake(host: host, peer: peer)

        await peer.main.runScheduler(.update)
        #expect(peer.main.getResource(ScriptNetworkCapture.self)?.amount == 0)
        await peer.main.runScheduler(.networkSend)
        await host.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.update)

        let capture = try #require(host.main.getResource(ScriptNetworkCapture.self))
        #expect(capture.amount == 27)
        #expect(capture.source == peerID.rawValue.uuidString)
    }

    @MainActor
    private func makeApp(
        role: NetworkRole,
        sessionID: SessionID,
        peerID: PeerID,
        compatibility: NetworkCompatibility,
        transport: any MultiplayerTransport,
        shouldSend: Bool
    ) async throws -> AppWorlds {
        let script = try AdaScriptPlugin(source: Self.source, name: "TypedNetwork-\(role.rawValue)")
        let app = AppWorlds(main: World(name: role.rawValue))
        app
            .addPlugin(
                MultiplayerPlugin(
                    configuration: MultiplayerConfiguration(
                        role: role,
                        sessionID: sessionID,
                        localPeerID: peerID,
                        compatibility: compatibility,
                        snapshotsPerSecond: 1_000
                    ),
                    transport: transport
                )
            )
            .insertResource(ScriptNetworkCapture())
            .insertResource(ScriptNetworkTrigger(shouldSend: shouldSend))
            .addPlugin(script)
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

    @MainActor
    private func registerResources() {
        RuntimeTypeRegistry.registerResource(ScriptNetworkCapture.self, names: ["ScriptNetworkCapture"])
        RuntimeResourceReflectionRegistry.register(
            ScriptNetworkCapture.self,
            fields: [Self.amountField, Self.sourceField]
        )
        RuntimeTypeRegistry.registerResource(ScriptNetworkTrigger.self, names: ["ScriptNetworkTrigger"])
        RuntimeResourceReflectionRegistry.register(
            ScriptNetworkTrigger.self,
            fields: [Self.shouldSendField]
        )
    }

    @safe
    private static let amountField = unsafe ReflectedComponentField(
        key: "amount",
        label: "amount",
        kind: .int,
        isWritable: true,
        accepts: { ComponentReflection.accepts($0, for: Int.self) },
        read: { _ in nil },
        write: { _, _ in nil },
        readPointer: { pointer in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptNetworkCapture.self)
            return ComponentReflection.read(unsafe resource.pointee.amount)
        },
        writePointer: { pointer, value in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptNetworkCapture.self)
            return unsafe ComponentReflection.write(value, to: &resource.pointee.amount)
        }
    )

    @safe
    private static let sourceField = unsafe ReflectedComponentField(
        key: "source",
        label: "source",
        kind: .string,
        isWritable: true,
        accepts: { ComponentReflection.accepts($0, for: String.self) },
        read: { _ in nil },
        write: { _, _ in nil },
        readPointer: { pointer in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptNetworkCapture.self)
            return ComponentReflection.read(unsafe resource.pointee.source)
        },
        writePointer: { pointer, value in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptNetworkCapture.self)
            return unsafe ComponentReflection.write(value, to: &resource.pointee.source)
        }
    )

    @safe
    private static let shouldSendField = unsafe ReflectedComponentField(
        key: "shouldSend",
        label: "shouldSend",
        kind: .bool,
        isWritable: true,
        accepts: { ComponentReflection.accepts($0, for: Bool.self) },
        read: { _ in nil },
        write: { _, _ in nil },
        readPointer: { pointer in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptNetworkTrigger.self)
            return ComponentReflection.read(unsafe resource.pointee.shouldSend)
        },
        writePointer: { pointer, value in
            let resource = unsafe pointer.assumingMemoryBound(to: ScriptNetworkTrigger.self)
            return unsafe ComponentReflection.write(value, to: &resource.pointee.shouldSend)
        }
    )

    private static let source = """
    @system(id: "typed.network")
    class TypedNetworkSystem {
        @rpc(
            id: "tests.adascript-input",
            delivery: "unreliable_sequenced",
            channel: "input"
        )
        func ScriptInput(@network_field(1) amount = 0) {
            capture.source = source;
            capture.amount = amount;
        }

        @res var multiplayer: Multiplayer;
        @res var capture: ScriptNetworkCapture;
        @res var trigger: ScriptNetworkTrigger;

        func update(context) {
            if (trigger.shouldSend) {
                multiplayer.send(ScriptInput(27));
                trigger.shouldSend = false;
            }
        }
    }
    """
}

private struct ScriptNetworkCapture: Resource {
    var amount = 0
    var source = ""
}

private struct ScriptNetworkTrigger: Resource {
    var shouldSend: Bool
}

@NetworkCommand(
    id: "tests.cross-language",
    delivery: .unreliableSequenced,
    channel: "input"
)
private struct SwiftCrossLanguageCommand {
    @NetworkField(1)
    var amount: Int
}
