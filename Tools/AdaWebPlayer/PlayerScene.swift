import AdaEngine
import AdaMultiplayer
import AdaScriptCompilerCore
import Foundation
import Yams

/// The portable subset of `.ascn` needed by the scene-backed Web Player.
struct PlayerSceneDocument: Decodable, Sendable {
    struct Identity: Decodable, Sendable {
        let id: String
        let name: String
    }

    struct Entity: Decodable, Sendable {
        struct Components: Decodable, Sendable {
            struct TransformValue: Decodable, Sendable {
                let position: [Float]
                let rotation: [Float]
                let scale: [Float]
            }

            struct VisibilityValue: Decodable, Sendable { let value: String }
            struct TileMapValue: Decodable, Sendable {
                let map: String
                let tileDisplaySize: [Float]
            }

            let transform: TransformValue?
            let visibility: VisibilityValue?
            let tileMap: TileMapValue?

            enum CodingKeys: String, CodingKey {
                case transform = "AdaTransform.Transform"
                case visibility = "AdaRender.Visibility"
                case tileMap = "AdaTilemap.TileMapComponent"
            }
        }

        let id: String
        let name: String
        let enabled: Bool
        let components: Components
    }

    let format: String
    let schemaVersion: Int
    let scene: Identity
    let entities: [Entity]

    static func load(project: AdaWebPlayerProject, directory: URL) throws -> Self {
        guard let entryScene = project.entryScene else {
            throw AdaWebPlayerProjectError.invalid("Scene profile has no entry scene.")
        }
        let url = try project.resourceURL(entryScene, at: directory)
        let scene = try YAMLDecoder().decode(Self.self, from: String(contentsOf: url, encoding: .utf8))
        guard scene.format == "ada.scene", scene.schemaVersion == 1 else {
            throw AdaWebPlayerProjectError.invalid("Unsupported scene format or version.")
        }
        return scene
    }
}

struct PlayerTileMap: Decodable, Sendable {
    let atlasColors: [Color]
    let atlasTextures: [String]?
    let tileSetReference: String?
    let tileSetTiles: [TileMapSourceTile]?
    let cells: [[Int]]
}

struct PlayerTileMapResource: Sendable {
    let map: PlayerTileMap
    let images: [Image]
    let linkedImages: [Image]
}

private struct PlayerTileSet: Decodable {
    struct Tile: Decodable { let xy: [Int] }
    struct Data: Decodable {
        let id: Int
        let image: TileSourceImageDescriptor?
        let tiles: [Tile]
    }
    struct Source: Decodable {
        let type: String
        let data: Data
    }
    let sources: [Source]
}

struct PlayerAdaProjectSettings: Decodable, Sendable {
    struct MultiplayerSettings: Decodable, Sendable {
        let buildIdentifier: String
        let gameIdentifier: String
    }
    struct PluginSettings: Decodable, Sendable { let multiplayer: MultiplayerSettings }
    struct Runtime: Decodable, Sendable { let plugins: Plugins }
    struct Plugins: Decodable, Sendable {
        let enable: [String]?
        let disable: [String]?
        let settings: PluginSettings

        var multiplayerEnabled: Bool {
            enable?.contains("multiplayer") == true && disable?.contains("multiplayer") != true
        }
    }

    let inputActions: [InputAction]
    let runtime: Runtime

    static func load(from directory: URL) throws -> Self {
        let staged = directory.appendingPathComponent("runtime-settings.json")
        let source = FileManager.default.fileExists(atPath: staged.path)
            ? staged : directory.appendingPathComponent(".ada/project.json")
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: source))
    }
}

struct PlayerSceneEntryPlugin: Plugin {
    let scene: PlayerSceneDocument
    let tileMaps: [String: PlayerTileMapResource]

    @MainActor
    func setup(in app: borrowing AppWorlds) {
        for item in scene.entities {
            let entity = app.main.spawn(item.name)
            entity.isActive = item.enabled
            if let value = item.components.transform,
                value.position.count == 3,
                value.rotation.count == 4,
                value.scale.count == 3 {
                app.main.insert(
                    Transform(
                        rotation: Quat(x: value.rotation[0], y: value.rotation[1], z: value.rotation[2], w: value.rotation[3]),
                        scale: Vector3(value.scale[0], value.scale[1], value.scale[2]),
                        position: Vector3(value.position[0], value.position[1], value.position[2])
                    ),
                    for: entity.id
                )
            }
            if item.components.visibility?.value == "hidden" {
                app.main.insert(Visibility.hidden, for: entity.id)
            }
            if let value = item.components.tileMap, let resource = tileMaps[value.map] {
                let tileMap = TileMap()
                do {
                    if !resource.images.isEmpty {
                        try tileMap.setImagePalette(resource.images, cells: resource.map.cells)
                    }
                    if !resource.linkedImages.isEmpty {
                        try tileMap.installLinkedImagePalette(
                            resource.linkedImages,
                            cells: resource.map.cells,
                            firstPaletteIndex: max(resource.map.atlasColors.count, resource.map.atlasTextures?.count ?? 0)
                        )
                    }
                } catch {
                    print("[AdaWebPlayer] Invalid tile map: \(error)")
                    continue
                }
                let size = value.tileDisplaySize
                if size.count == 2 {
                    app.main.insert(
                        TileMapComponent(tileMap: tileMap, tileDisplaySize: Size(width: size[0], height: size[1])),
                        for: entity.id
                    )
                }
            }
        }
    }
}

extension PlayerSceneDocument {
    func loadTileMaps(project: AdaWebPlayerProject, directory: URL) throws -> [String: PlayerTileMapResource] {
        var maps: [String: PlayerTileMapResource] = [:]
        for item in entities {
            guard let reference = item.components.tileMap?.map else { continue }
            guard reference.hasPrefix("@res://") else {
                throw AdaWebPlayerProjectError.invalid("Tile map reference must use @res://")
            }
            let path = "Assets/" + String(reference.dropFirst("@res://".count))
            let url = try project.resourceURL(path, at: directory)
            let map = try YAMLDecoder().decode(PlayerTileMap.self, from: String(contentsOf: url, encoding: .utf8))
            let images: [Image]
            if let paths = map.atlasTextures, !paths.isEmpty {
                var textured = try paths.map { path in
                    try Image(contentsOf: URL(fileURLWithPath: path, relativeTo: url.deletingLastPathComponent()).standardizedFileURL)
                }
                if let first = textured.first {
                    for color in map.atlasColors.dropFirst(textured.count) {
                        textured.append(Image(width: first.width, height: first.height, color: color))
                    }
                }
                images = textured
            } else {
                images = map.atlasColors.map { Image(width: 1, height: 1, color: $0) }
            }
            let linkedImages = try loadLinkedTileImages(map: map, project: project, directory: directory)
            maps[reference] = PlayerTileMapResource(map: map, images: images, linkedImages: linkedImages)
        }
        return maps
    }

    private func loadLinkedTileImages(map: PlayerTileMap, project: AdaWebPlayerProject, directory: URL) throws -> [Image] {
        guard let reference = map.tileSetReference, !reference.isEmpty else { return [] }
        guard reference.hasPrefix("@res://") else {
            throw AdaWebPlayerProjectError.invalid("Tile set reference must use @res://")
        }
        let path = "Assets/" + String(reference.dropFirst("@res://".count))
        let tileSetURL = try project.resourceURL(path, at: directory)
        let tileSet = try YAMLDecoder().decode(PlayerTileSet.self, from: String(contentsOf: tileSetURL, encoding: .utf8))
        var sourceImages: [Int: Image] = [:]
        var result: [Image] = []
        for tile in map.tileSetTiles ?? [] {
            guard tile.atlasCoordinates.count == 2,
                let source = tileSet.sources.first(where: { $0.data.id == tile.sourceID }),
                source.type == String(reflecting: TextureAtlasTileSource.self),
                let descriptor = source.data.image,
                source.data.tiles.contains(where: { $0.xy == tile.atlasCoordinates }) else {
                throw AdaWebPlayerProjectError.invalid("Linked tile is missing from \(reference).")
            }
            let image: Image
            if let cached = sourceImages[tile.sourceID] {
                image = cached
            } else {
                let imageURL: URL
                if descriptor.path.hasPrefix("@res://") {
                    imageURL = try project.resourceURL("Assets/" + String(descriptor.path.dropFirst("@res://".count)), at: directory)
                } else {
                    let candidate = URL(fileURLWithPath: descriptor.path, relativeTo: tileSetURL.deletingLastPathComponent()).standardizedFileURL
                    let root = directory.standardizedFileURL.path
                    guard candidate.path.hasPrefix(root + "/") else {
                        throw AdaWebPlayerProjectError.invalid("Tile source image escapes the project.")
                    }
                    imageURL = try project.resourceURL(String(candidate.path.dropFirst(root.count + 1)), at: directory)
                }
                image = try Image(contentsOf: imageURL)
                sourceImages[tile.sourceID] = image
            }
            let x = descriptor.margin.width + tile.atlasCoordinates[0] * (descriptor.tileSize.width + descriptor.spacing.width)
            let y = descriptor.margin.height + tile.atlasCoordinates[1] * (descriptor.tileSize.height + descriptor.spacing.height)
            guard x >= 0, y >= 0, x + descriptor.tileSize.width <= image.width,
                y + descriptor.tileSize.height <= image.height else {
                throw AdaWebPlayerProjectError.invalid("Linked tile is outside its image.")
            }
            var sliced = Image(width: descriptor.tileSize.width, height: descriptor.tileSize.height)
            for row in 0..<descriptor.tileSize.height {
                for column in 0..<descriptor.tileSize.width {
                    sliced.setPixel(in: [Float(column), Float(row)], color: image.getPixel(x: x + column, y: y + row))
                }
            }
            result.append(sliced)
        }
        return result
    }
}

@MainActor
struct PlayerScene {
    let view: AnyView

    init(project: AdaWebPlayerProject, sources: [AdaScriptSource], directory: URL) throws {
        let scene = try PlayerSceneDocument.load(project: project, directory: directory)
        let tileMaps = try scene.loadTileMaps(project: project, directory: directory)
        let settings = try PlayerAdaProjectSettings.load(from: directory)

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

        let script = try AdaScriptPlugin(
            sources: sources,
            name: project.moduleName ?? project.title,
            startupSystemIdentifier: project.startupSystem
        )
        let configuration: MultiplayerConfiguration?
        let transport: (any MultiplayerTransport)?
        if settings.runtime.plugins.multiplayerEnabled {
            let compatibility = NetworkCompatibility(
                gameIdentifier: settings.runtime.plugins.settings.multiplayer.gameIdentifier,
                buildIdentifier: settings.runtime.plugins.settings.multiplayer.buildIdentifier
            )
            #if os(WASI)
                if let session = try PlayerBrowserSession.current() {
                    configuration = MultiplayerConfiguration(
                        role: session.role,
                        sessionID: SessionID(rawValue: session.sessionID),
                        localPeerID: PeerID(rawValue: session.peerID),
                        compatibility: compatibility,
                        snapshotsPerSecond: 20,
                        disconnectGracePeriod: 10
                    )
                    transport = CloudWebSocketTransport(credentials: CloudRelayCredentials(
                        url: session.relayURL,
                        connectionTicket: session.connectionTicket
                    ))
                } else if PlayerBrowserSession.soloMode {
                    configuration = MultiplayerConfiguration(role: .host, compatibility: compatibility)
                    transport = InMemoryTransport(hub: InMemoryTransportHub())
                } else {
                    throw AdaWebPlayerProjectError.invalid("Create or join a multiplayer room before starting the game.")
                }
            #else
                configuration = MultiplayerConfiguration(role: .host, compatibility: compatibility)
                transport = InMemoryTransport(hub: InMemoryTransportHub())
            #endif
        } else {
            configuration = nil
            transport = nil
        }
        self.view = AnyView(
            SceneView(
                make: { app in
                    app.addPlugin(TransformPlugin())
                    app.addPlugin(InputPlugin(actions: settings.inputActions))
                    app.addPlugin(RenderWorldPlugin())
                    app.addPlugin(EventsPlugin())
                    app.addPlugin(CameraPlugin())
                    app.addPlugin(AssetsPlugin(assetDirectory: directory.appendingPathComponent("Assets", isDirectory: true)))
                    app.addPlugin(VisibilityPlugin())
                    app.addPlugin(ScenePlugin())
                    app.addPlugin(Core2DPlugin())
                    app.addPlugin(Mesh2DPlugin())
                    app.addPlugin(SpritePlugin())
                    app.addPlugin(TileMapPlugin())
                    if let configuration, let transport {
                        app.addPlugin(MultiplayerPlugin(configuration: configuration, transport: transport))
                        app.addPlugin(AdaScriptMultiplayerBridgePlugin(configuration: configuration))
                    }
                    app.addPlugin(script)
                    app.addPlugin(PlayerSceneEntryPlugin(scene: scene, tileMaps: tileMaps))
                },
                updateContent: { _, _ in }
            )
        )
    }
}
