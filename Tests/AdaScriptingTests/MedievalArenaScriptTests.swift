@_spi(Internal) import AdaApp
import AdaAssets
import AdaECS
@_spi(Internal) import AdaInput
import AdaMultiplayer
import AdaRender
import AdaScripting
import AdaSprite
import AdaTransform
import Foundation
import Testing
import Yams

@Suite("Medieval Arena AdaScript boundary", .serialized)
struct MedievalArenaScriptTests {
    @Test("Gameplay is authored in the project, not engine or editor")
    @MainActor
    func gameplayBelongsToAdaScriptProject() throws {
        Self.registerRuntimeTypes()
        #expect(Transform.runtimeComponentConstructor.parameters.map(\.name) == ["rotation", "scale", "position"])
        #expect(Sprite.runtimeComponentConstructor.parameters.map(\.name) == ["texture", "tintColor", "flipX", "flipY"])
        try AdaScriptPlugin.validate(
            sources: [
                AdaScriptSource(
                    path: "BridgeProbe.ada",
                    source: """
                    @system(id: "bridge.probe")
                    class BridgeProbeSystem {
                        @res var multiplayer: AdaScriptMultiplayerState;
                        func update(context) {}
                    }
                    """
                )
            ],
            name: "BridgeProbe"
        )
        let gameRoot = Self.repositoryRoot.appendingPathComponent("Demos/MedievalArena", isDirectory: true)
        let sourceRoot = gameRoot.appendingPathComponent("Sources", isDirectory: true)
        let sourceURLs = try FileManager.default.contentsOfDirectory(
            at: sourceRoot,
            includingPropertiesForKeys: nil
        )
        .filter { $0.pathExtension == "ada" }
        .sorted { $0.lastPathComponent < $1.lastPathComponent }
        let sources = try sourceURLs.map {
            AdaScriptSource(path: $0.lastPathComponent, source: try String(contentsOf: $0, encoding: .utf8))
        }
        let gameSource = sources.map(\.source).joined(separator: "\n")

        #expect(sourceURLs.map(\.lastPathComponent) == [
            "ArenaGameplay.ada",
            "ArenaInput.ada",
            "ArenaPresentation.ada",
            "ArenaState.ada",
        ])
        #expect(gameSource.contains("class ArenaGameplaySystem"))
        #expect(gameSource.contains("func applyAttack"))
        #expect(gameSource.contains("target.arenaPlayer.health -= 1"))
        #expect(gameSource.contains("@replicated_component"))
        #expect(!gameSource.contains("publishedSnapshot"))
        #expect(!gameSource.contains("receivedSnapshot"))
        #expect(gameSource.contains("class ArenaPresentationSystem"))
        #expect(gameSource.contains("ArenaGame.swords"))
        try AdaScriptPlugin.validate(sources: sources, name: "MedievalArenaGame")

        for relativeDirectory in ["Sources", "Editor/Sources"] {
            let url = Self.repositoryRoot.appendingPathComponent(relativeDirectory, isDirectory: true)
            let enumerator = try #require(FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil))
            let swiftSources = try enumerator.compactMap { value -> String? in
                guard let fileURL = value as? URL, fileURL.pathExtension == "swift" else {
                    return nil
                }
                return try String(contentsOf: fileURL, encoding: .utf8)
            }
            let nativeSource = swiftSources.joined(separator: "\n")
            #expect(!nativeSource.contains("ArenaGameplaySystem"))
            #expect(!nativeSource.contains("ArenaPlayerState"))
            #expect(!nativeSource.contains("ArenaSwordEffect"))
            #expect(!nativeSource.contains("setupArenaContent"))
        }
    }

    @Test("Scene owns one populated TileMap and explicit spawn markers")
    func sceneContainsAuthoredArena() throws {
        struct ArenaScene: Decodable {
            struct Entity: Decodable {
                struct Components: Decodable {
                    struct TileMap: Decodable {
                        var cells: [[Int]]?
                        var map: String?
                    }

                    var tileMap: TileMap?

                    enum CodingKeys: String, CodingKey {
                        case tileMap = "AdaTilemap.TileMapComponent"
                    }
                }

                var components: Components?
                var id: String
            }

            var entities: [Entity]
        }

        let sceneURL = Self.repositoryRoot
            .appendingPathComponent("Demos/MedievalArena/Assets/Scenes/Main.ascn")
        let scene = try YAMLDecoder().decode(
            ArenaScene.self,
            from: String(contentsOf: sceneURL, encoding: .utf8)
        )
        let tileMap = try #require(scene.entities.first { $0.id == "arena-tilemap" }?.components?.tileMap)
        let cells: [[Int]]
        if let authoredCells = tileMap.cells {
            cells = authoredCells
        } else {
            let mapReference = try #require(tileMap.map)
            #expect(mapReference == "@res://Maps/Arena.tilemap")
            struct MapAsset: Decodable { let cells: [[Int]] }
            let mapURL = Self.repositoryRoot.appendingPathComponent("Demos/MedievalArena/Assets/Maps/Arena.tilemap")
            cells = try YAMLDecoder().decode(MapAsset.self, from: String(contentsOf: mapURL, encoding: .utf8)).cells
        }
        let entityIDs = Set(scene.entities.map(\.id))

        #expect(cells.count >= 19 * 11)
        #expect(entityIDs.contains("host-spawn"))
        #expect(entityIDs.contains("peer-spawn"))
        #expect(scene.entities.count == 5)
    }

    @Test("Project owns its input bindings")
    func projectOwnsInputBindings() throws {
        struct ProjectInput: Decodable {
            var inputActions: [InputAction]
        }
        let projectURL = Self.repositoryRoot
            .appendingPathComponent("Demos/MedievalArena/.ada/project.json")
        let project = try JSONDecoder().decode(ProjectInput.self, from: Data(contentsOf: projectURL))

        #expect(project.inputActions.map(\.name) == ["MoveUp", "MoveDown", "MoveLeft", "MoveRight", "Attack"])
        #expect(project.inputActions.last?.bindings == [.key(.space)])
    }

    @MainActor
    @Test("Host gameplay executes through the pure AdaScript systems")
    func hostGameplayExecutes() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "MedievalArenaRenderSetup")))
        }
        Self.registerRuntimeTypes()

        let world = World(name: "MedievalArenaScriptHost")
        let app = AppWorlds(main: world)
        AssetsPlugin(assetDirectory: Self.repositoryRoot.appendingPathComponent("Demos/MedievalArena/Assets", isDirectory: true)).setup(in: app)
        InputPlugin(actions: [InputAction(name: "Attack", bindings: [.key(.space)])]).setup(in: app)
        world.insertResource(DeltaTime(deltaTime: 1.0 / 60.0))
        let peerUUID = try #require(UUID(uuidString: "4D415045-4552-4000-8000-000000000001"))
        MultiplayerPlugin(
            configuration: MultiplayerConfiguration(
                role: .host,
                localPeerID: PeerID(rawValue: peerUUID),
                compatibility: NetworkCompatibility(
                    gameIdentifier: "medieval-arena-script-tests",
                    buildIdentifier: "1"
                )
            ),
            transport: InMemoryTransport(hub: InMemoryTransportHub())
        ).setup(in: app)
        world.insertResource(
            AdaScriptMultiplayerState(
                role: .host,
                localPeerID: PeerID(rawValue: peerUUID)
            )
        )
        let plugin = try AdaScriptPlugin(sources: try Self.gameSources(), name: "MedievalArenaGame")
        plugin.setup(in: app)
        world.getRefResource(Input.self).wrappedValue.receiveEvent(
            KeyEvent(
                window: .empty,
                keyCode: .space,
                modifiers: [],
                status: .down,
                time: 0,
                isRepeated: false
            )
        )

        await AppWorldsExecutionContext.$currentID.withValue(app.executionID) {
            for _ in 0..<40 {
                await world.runScheduler(.preUpdate)
                await world.runScheduler(.update)
                await world.runScheduler(.postUpdate)
            }
        }

        #expect(plugin.diagnostics.isEmpty, Comment(rawValue: plugin.diagnostics.joined(separator: "\n")))
        // ArenaPlayer is now a real replicated ECS entity plus four persistent visuals.
        // A sixth entity can be the short-lived sword presentation.
        #expect((5...6).contains(world.getEntities().count))
        let descriptor = try #require(world.runtimeComponentDescriptor(named: "ArenaPlayer"))
        let playerEntity = try #require(world.getEntities().first(where: {
            world.getRuntimeComponent(descriptor.componentID, from: $0.id) != nil
        }))
        let player = try #require(world.getRuntimeComponent(descriptor.componentID, from: playerEntity.id))
        #expect(player.values[0] == .string(peerUUID.uuidString))
        #expect(world.get(ReplicatedEntity.self, from: playerEntity.id) != nil)
        let playerSprite = try #require(world.getEntities().compactMap { world.get(Sprite.self, from: $0.id) }
            .first { $0.texture?.asset?.assetName == "tile_0096.png" })
        #expect(playerSprite.texture?.asset != nil)
    }

    @MainActor
    private static func registerRuntimeTypes() {
        RuntimeTypeRegistry.registerComponent(
            Transform.self,
            names: ["Transform"],
            makeDefault: { Transform() }
        )
        RuntimeTypeRegistry.registerComponent(
            Sprite.self,
            names: ["Sprite"],
            makeDefault: { Sprite(texture: Texture2D.whiteTexture) }
        )
        ComponentReflectionRegistry.register(Transform.componentDescriptor)
        ComponentReflectionRegistry.register(Sprite.componentDescriptor)
        AdaScriptMultiplayerState.registerRuntimeType()
    }

    private static var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func gameSources() throws -> [AdaScriptSource] {
        let sourceRoot = repositoryRoot.appendingPathComponent("Demos/MedievalArena/Sources", isDirectory: true)
        return try FileManager.default.contentsOfDirectory(at: sourceRoot, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "ada" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { AdaScriptSource(path: $0.lastPathComponent, source: try String(contentsOf: $0, encoding: .utf8)) }
    }
}
