@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaApp
@_spi(Internal) import AdaAssets
import AdaMultiplayer
import AdaScriptCompilerCore
import Foundation
import Observation

@MainActor
@Observable
final class EditorCommunityPlayerModel {
    private(set) var session: EditorCommunityPlayerSession?
    private(set) var error: String?
    private(set) var loading = false
    let game: EditorCommunityGame
    let client: EditorCommunityClient
    private let store: EditorCommunityPackageStore
    private(set) var directory: URL?
    private(set) var currentGame: EditorCommunityGame?
    private(set) var choosingMode = false
    private(set) var room: EditorCommunityRoom?
    var joinCode = ""
    var networkError: String?

    init(game: EditorCommunityGame, client: EditorCommunityClient, store: EditorCommunityPackageStore = .shared) {
        self.game = game; self.client = client; self.store = store
    }

    func load() async {
        guard !loading else { return }
        loading = true; error = nil; session = nil
        defer { loading = false }
        do {
            let current = game.isPreview ? game : try await client.game(id: game.id)
            let directory = try await store.load(game: current, client: client)
            try Task.checkCancellation()
            self.directory = directory
            currentGame = current
            room = nil
            session = try EditorCommunityPlayerSession(directory: directory, gameID: game.id, releaseID: Self.release(current), apiVersion: current.apiVersion)
            choosingMode = session?.artifact.plugins.contains(.multiplayer) == true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func solo() { choosingMode = false; networkError = nil }

    func connect(host: Bool) async {
        guard !loading, let directory, let currentGame else { return }
        loading = true; networkError = nil
        defer { loading = false }
        do {
            let multiplayer = EditorCommunityMultiplayerClient(server: client.server)
            let room = try await (host ? multiplayer.create(gameID: game.id, buildID: Self.release(currentGame)) : multiplayer.join(code: joinCode, gameID: game.id, buildID: Self.release(currentGame)))
            try Task.checkCancellation()
            self.session = try EditorCommunityPlayerSession(directory: directory, gameID: game.id, releaseID: Self.release(currentGame), apiVersion: currentGame.apiVersion, room: room)
            self.room = room
            choosingMode = false
        } catch { if !Task.isCancelled { networkError = error.localizedDescription } }
    }

    private static func release(_ game: EditorCommunityGame) -> String {
        if case .adaScript(let release) = game.runtime { return release }
        return game.id
    }

    func stop() { session = nil; room = nil }
}

@MainActor
private final class CommunityPreparationScope {
    let id = UUID()
    init(directories: ProjectDirectories) {
        AssetsManager.initialize(directories: directories, scopeID: id)
    }
    deinit {
        let scopeID = id
        Task { await AssetsManager.destroyScope(scopeID) }
    }
}

@MainActor
final class EditorCommunityPlayerSession {
    private let preparation: CommunityPreparationScope
    var preparationScopeID: UUID { preparation.id }
    let artifact: EditorAdaScriptProjectBuildArtifact
    let script: AdaScriptPlugin
    let directories: ProjectDirectories
    let catalog: AdaScriptObjectCatalog
    let network: EditorCommunityNetworkPlugin?
    var diagnostics: [String] { script.diagnostics + catalog.diagnostics }

    init(directory: URL, gameID: String, releaseID: String? = nil, apiVersion: Int = 1, room: EditorCommunityRoom? = nil) throws {
        let project = try JSONDecoder().decode(AdaProject.self, from: Data(contentsOf: directory.appendingPathComponent(".ada/project.json")))
        guard ProjectSystem.supportedSchemaVersions.contains(project.schemaVersion), project.build.system.isAdaScript,
              (project.paths.sources ?? "Sources") == "Sources", (project.paths.assets ?? "Assets") == "Assets",
              project.paths.resourceRoots.allSatisfy({ $0 == "Assets" }), project.runtime.entry.view == nil,
              project.runtime.entry.scene != nil || project.runtime.entry.startupSystem != nil else { throw EditorCommunityPackageManifest.Failure.incompatibleProject }
        if let scene = project.runtime.entry.scene {
            guard EditorCommunityPackageManifest.validPath(scene), scene.hasPrefix("Assets/"), scene.hasSuffix(".ascn") else { throw EditorCommunityPackageManifest.Failure.invalidPackage }
        }
        EditorComponentRegistry.registerBuiltIns()
        AdaScriptMultiplayerState.registerRuntimeType()
        let assets = directory.appendingPathComponent("Assets")
        let support = (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory)
            .appendingPathComponent("AdaStudioCommunity").appendingPathComponent(directory.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent).appendingPathComponent(gameID)
        let roots = ProjectDirectories(source: directory, assetsDirectory: assets, userDataDirectory: support.appendingPathComponent("Saves"), cacheDirectory: support.appendingPathComponent("Cache"), restrictToVirtualRoots: true)
        directories = roots
        let preparation = CommunityPreparationScope(directories: roots)
        self.preparation = preparation
        artifact = try AppWorldsExecutionContext.$currentID.withValue(preparation.id) {
            try EditorAdaScriptProjectBuilder().prepare(project: project, at: directory, validatesRuntime: false)
        }
        let allowed: Set<String> = ["core2d", "sprite", "light2d", "mesh2d", "tilemap", "physics2d", "audio", "upscale", "core3d", "model3d", "physics3d", "multiplayer"]
        guard artifact.plugins.pluginIDs.allSatisfy({ allowed.contains($0.rawValue) }) else {
            throw EditorCommunityPackageManifest.Failure.incompatibleProject
        }
        let advanced = artifact.plugins.contains(.core3D) || artifact.plugins.contains(.model3D) || artifact.plugins.contains(.physics3D) || artifact.plugins.contains(.multiplayer) || !artifact.scenePlayRuntime.schemas.isEmpty
        guard !advanced || apiVersion >= 2 else { throw EditorCommunityPackageManifest.Failure.incompatibleProject }
        try EditorCommunityModelAssets.validate(in: directory)
        let schemas = artifact.scenePlayRuntime.schemas, sources = artifact.sources
        catalog = try AppWorldsExecutionContext.$currentID.withValue(preparation.id) {
            try AdaScriptObjectCatalog(schemas: schemas, sources: sources, communityPolicy: AdaScriptCommunityPolicy())
        }
        if artifact.plugins.contains(.multiplayer) {
            let compatibility = NetworkCompatibility(gameIdentifier: gameID, buildIdentifier: releaseID ?? gameID)
            let configuration: MultiplayerConfiguration
            let transport: any MultiplayerTransport
            if let room {
                guard room.gameID == gameID, room.buildID == releaseID else { throw EditorCommunityMultiplayerError.unavailable }
                configuration = MultiplayerConfiguration(role: room.role, sessionID: SessionID(rawValue: room.sessionID), localPeerID: PeerID(rawValue: room.peerID), compatibility: compatibility, snapshotsPerSecond: 20, disconnectGracePeriod: 10)
                transport = CloudWebSocketTransport(credentials: room.relay)
            } else {
                configuration = MultiplayerConfiguration(role: .host, compatibility: compatibility)
                transport = InMemoryTransport(hub: InMemoryTransportHub())
            }
            network = EditorCommunityNetworkPlugin(configuration: configuration, transport: transport)
        } else { network = nil }
        // Restrict every packaged scene, including destinations used by scene navigation.
        if let files = FileManager.default.enumerator(at: assets, includingPropertiesForKeys: nil) {
            for case let file as URL in files where file.pathExtension == "ascn" {
                let model = try EditorSceneModel.decode(from: String(contentsOf: file, encoding: .utf8))
                let components: Set<String> = ["Transform", "Visibility", "BoundingComponent", "NoFrustumCulling", "Camera", "Camera2D", "OrthographicCamera", "Sprite", "Light2D", "LightOccluder2D", "LightModulate2D", "Mesh2D", "PhysicsBody2DComponent", "RigidBody2D", "Collider2D", "TileMapComponent", "TextComponent", "Mesh3D", "Mesh3DComponent", "Model3DSource", "DirectionalLight", "DirectionalLightComponent", "PointLight", "PointLightComponent", "SpotLight", "SpotLightComponent", "LightEnvironment", "ImageBasedLight", "Environment3D", "PhysicsBody3DComponent", "RigidBody3D", "Collider3D", "ScriptableComponents", "ReplicatedEntity", "NetworkOwner"]
                guard model.entities.count <= 2048, model.entities.allSatisfy({ Set($0.components.keys.map { $0.split(separator: ".").last.map(String.init) ?? $0 }).isSubset(of: components) }) else {
                    throw EditorCommunityPackageManifest.Failure.incompatibleProject
                }
            }
        }
        let moduleName = artifact.moduleName, startup = artifact.entry.startupSystem
        script = try AppWorldsExecutionContext.$currentID.withValue(preparation.id) {
            try AdaScriptPlugin(sources: sources, name: moduleName, startupSystemIdentifier: startup, communityPolicy: AdaScriptCommunityPolicy())
        }
    }

    func configure(_ app: inout AppWorlds) {
        app.runtimeLogSource = "Community"
        app.addPlugin(TransformPlugin())
        app.addPlugin(InputPlugin(actions: artifact.scenePlayRuntime.inputActions))
        app.addPlugin(RenderWorldPlugin())
        app.addPlugin(EventsPlugin())
        app.addPlugin(CameraPlugin())
        app.addPlugin(AssetsPlugin(directories: directories))
        app.addPlugin(VisibilityPlugin())
        app.addPlugin(TextPlugin())
        app.addPlugin(ScenePlugin(includesModel3D: artifact.plugins.contains(.model3D)))
        for plugin in artifact.plugins.pluginIDs {
            switch plugin {
            case .core2D: app.addPlugin(Core2DPlugin())
            case .core3D: app.addPlugin(Core3DPlugin())
            case .physics3D: app.addPlugin(Physics3DPlugin())
            case .sprite: app.addPlugin(SpritePlugin())
            case .light2D: app.addPlugin(Light2DPlugin())
            case .mesh2D: app.addPlugin(Mesh2DPlugin())
            case .tilemap: app.addPlugin(TileMapPlugin())
            case .physics2D:
                let gravity = artifact.plugins.physics2DGravity
                app.addPlugin(Physics2DPlugin(gravity: [Float(gravity[0]), Float(gravity[1])]))
            case .audio: app.addPlugin(AudioPlugin())
            case .upscale: app.addPlugin(UpscalePlugin())
            default: break
            }
        }
        if let network { app.addPlugin(network) }
        app.addPlugin(EditorCommunityScriptsPlugin(catalog: catalog))
        app.addPlugin(script)
        if let scene = artifact.sceneModel {
            app.addPlugin(EditorAdaScriptRuntimeEntryPlugin(sceneModel: scene, assetsDirectory: artifact.assetsDirectory))
        }
    }
}

struct EditorCommunityPlayerView: View {
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss
    @State private var model: EditorCommunityPlayerModel
    @State private var loadTask: Task<Void, Never>?
    @State private var runtimeError: String?
    @State private var connectionMonitor: Task<Void, Never>?
    private let close: (@MainActor @Sendable () -> Void)?

    init(game: EditorCommunityGame, client: EditorCommunityClient, close: (@MainActor @Sendable () -> Void)? = nil) {
        self.close = close
        _model = State(wrappedValue: EditorCommunityPlayerModel(game: game, client: client))
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Button("Close") { if let close { close() } else { dismiss() } }.accessibilityIdentifier("AdaEditor.Community.Player.Close")
                Spacer()
                Text(model.game.title).lineLimit(1)
                Spacer()
                Button("Restart") { reload() }.disabled(model.loading || model.room != nil)
                    .accessibilityIdentifier("AdaEditor.Community.Player.Restart")
            }
            .font(.system(size: 16)).foregroundColor(theme.editorColors.text).padding(18)
            if let room = model.room {
                Text(room.joinCode.map { "Room code: " + $0 } ?? "Connected to room").font(.system(size: 14)).padding(8)
            }
            if let error = runtimeError ?? model.error {
                Spacer()
                Text("Couldn’t start this world").font(.system(size: 22))
                Text(error).font(.system(size: 14)).lineLimit(6).padding(22)
                Button("Try again") { reload() }
                Spacer()
            } else if model.choosingMode {
                multiplayerLobby
            } else if let session = model.session {
                SceneView(useSceneCameras: session.artifact.plugins.contains(.core3D), make: { app in session.configure(&app) }, updateContent: { world, _ in
                    if let diagnostic = session.diagnostics.first { runtimeError = diagnostic; model.stop() }
                    if model.room != nil, connectionMonitor == nil, let network = world.getResource(MultiplayerSession.self) {
                        connectionMonitor = Task { @MainActor in
                            while !Task.isCancelled {
                                if case .ended = await network.currentState() {
                                    runtimeError = "The multiplayer room has ended. Close this world to start or join another room."
                                    model.stop()
                                    return
                                }
                                try? await Task.sleep(for: .milliseconds(300))
                            }
                        }
                    }
                })
                .id(ObjectIdentifier(session))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityIdentifier("AdaEditor.Community.Player.Scene")
            } else {
                Spacer()
                Text("Loading world…").font(.system(size: 22))
                Text("Preparing your game.").font(.system(size: 14))
                Spacer()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .foregroundColor(theme.editorColors.text)
        .background(theme.editorColors.background.ignoresSafeArea())
        .accessibilityIdentifier("AdaEditor.Community.Player")
        .onAppear { reload() }
        .onDisappear { loadTask?.cancel(); connectionMonitor?.cancel(); model.stop() }
    }

    private var multiplayerLobby: some View {
        VStack(spacing: 18) {
            Spacer()
            Text("Play together").font(.system(size: 26))
            Button("Play solo") { model.solo() }.accessibilityIdentifier("AdaEditor.Community.Multiplayer.Solo")
            Button("Host a room") { connect(host: true) }.disabled(model.loading)
                .accessibilityIdentifier("AdaEditor.Community.Multiplayer.Host")
            TextField("Room code", text: Binding(get: { model.joinCode }, set: { model.joinCode = $0 }))
                .textFieldStyle(PlainTextFieldStyle()).padding(12)
                .background(RoundedRectangleShape(cornerRadius: 10).fill(theme.editorColors.surface))
                .accessibilityIdentifier("AdaEditor.Community.Multiplayer.Code")
            Button("Join room") { connect(host: false) }.disabled(model.loading || model.joinCode.count != 8)
                .accessibilityIdentifier("AdaEditor.Community.Multiplayer.Join")
            if let error = model.networkError { Text(error).font(.system(size: 14)).lineLimit(4) }
            if model.loading { Text("Connecting…") }
            Spacer()
        }
        .font(.system(size: 17)).padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func connect(host: Bool) {
        let previous = loadTask
        previous?.cancel()
        loadTask = Task { @MainActor in await previous?.value; guard !Task.isCancelled else { return }; await model.connect(host: host) }
    }

    private func reload() {
        connectionMonitor?.cancel(); connectionMonitor = nil
        let previous = loadTask
        previous?.cancel(); runtimeError = nil
        loadTask = Task { @MainActor in
            await previous?.value
            guard !Task.isCancelled else { return }
            await model.load()
        }
    }
}
