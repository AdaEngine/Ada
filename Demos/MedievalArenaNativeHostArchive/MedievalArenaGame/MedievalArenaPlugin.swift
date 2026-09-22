import AdaEngine
import AdaMultiplayer
import Foundation

public struct MedievalArenaPlugin: Plugin {
    private let launch: ArenaLaunchOptions

    public init(launch: ArenaLaunchOptions) {
        self.launch = launch
    }

    @MainActor
    public func setup(in app: borrowing AppWorlds) {
        let diagnostics = ArenaDiagnostics(path: launch.diagnosticsPath)
        let transport = LocalTCPTransport(host: launch.host, port: launch.port, diagnostics: diagnostics)
        let configuration = MultiplayerConfiguration(
            role: launch.role,
            sessionID: ArenaLaunchOptions.sessionID,
            localPeerID: launch.peerID,
            compatibility: NetworkCompatibility(
                gameIdentifier: "org.adaengine.medieval-arena",
                buildIdentifier: "1"
            ),
            snapshotsPerSecond: 20,
            disconnectGracePeriod: 2
        )

        MultiplayerPlugin(configuration: configuration, transport: transport).setup(in: app)
        app.registerReplicatedComponent(ArenaPlayerState.self, id: "medieval-arena.player", version: 1)
        app.registerNetworkCommand(ArenaInputCommand.self)

        ArenaInputState.registerRuntimeType()
        app.main.insertResource(ArenaInputState())
        app.main.insertResource(
            ArenaRuntime(
                role: launch.role,
                localPeerID: launch.peerID,
                runsBot: launch.runsBot,
                diagnostics: diagnostics
            )
        )
        app.main.insertResource(ArenaPresentationState())

        do {
            try app.main.getRefResource(Input.self).wrappedValue.setInputActions([
                InputAction(name: "MoveUp", bindings: [.key(.w), .key(.arrowUp)]),
                InputAction(name: "MoveDown", bindings: [.key(.s), .key(.arrowDown)]),
                InputAction(name: "MoveLeft", bindings: [.key(.a), .key(.arrowLeft)]),
                InputAction(name: "MoveRight", bindings: [.key(.d), .key(.arrowRight)]),
                InputAction(name: "Attack", bindings: [.key(.space)])
            ])
        } catch {
            diagnostics.record("input action setup failed: \(error)")
        }

        AdaScriptPluginsGenerated().setup(in: app)
        do {
            let controller = try ScriptableObjectRegistry.make(named: "medieval-arena.input")
            app.main.spawn("AdaScript input") {
                ScriptableComponents(scripts: [controller])
            }
        } catch {
            diagnostics.record("AdaScript input setup failed: \(error)")
        }

        app
            .addSystem(SetupArenaSystem.self, on: .startup)
            .addSystem(ArenaConnectionSystem.self)
            .addSystem(ArenaBotInputSystem.self)
            .addSystem(ArenaHostGameplaySystem.self)
            .addSystem(ArenaPeerInputSystem.self)
            .addSystem(ArenaPresentationSystem.self)
            .addSystem(ArenaSwordEffectSystem.self)
            .addSystem(ArenaStatusSystem.self)

        diagnostics.record("launch role=\(launch.role.rawValue) peer=\(launch.peerID.rawValue.uuidString)")
    }
}
