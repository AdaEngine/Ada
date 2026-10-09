@testable import AdaEditor
@_spi(Internal) import AdaApp
@_spi(Internal) import AdaRender
@_spi(AdaEngine) @testable import AdaEngine
import AdaMultiplayer
import Foundation
import Testing

@MainActor
@Suite("Community extended runtime", .serialized)
struct EditorCommunityExtendedTests {
    private let gameID = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
    private let buildID = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"

    private func bootstrap() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "Extended UGC")))
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        EditorComponentRegistry.registerBuiltIns()
    }

    private func project(source: String, preset: AdaProjectRuntimePluginPreset = .ui, multiplayer: Bool = false) throws -> URL {
        bootstrap()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ugc-v2-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
        var project = ProjectSystem.defaultProject(projectName: "CommunityV2", buildSystem: .adaScript)
        project.paths = .init(sources: "Sources", assets: "Assets")
        project.runtime.entry = .init(startupSystem: "game.start")
        project.runtime.plugins = .init(preset: preset, enable: multiplayer ? [.multiplayer] : [])
        try ProjectSystem.saveProject(project, at: root)
        let bootstrap = "@system(scheduler: \"startup\", id: \"game.start\") class Boot { func update(context) {} }"
        try (source + "\n" + bootstrap).write(to: root.appendingPathComponent("Sources/Game.ada"), atomically: true, encoding: .utf8)
        return root
    }

    @Test func scriptableScopesRunAndDoNotCollide() async throws {
        func source(_ amount: Int) -> String {
            "@scriptable(id: \"ugc.counter\") class Counter { @export var count = 0; func update(context) { count += \(amount); } }"
        }
        let first = try project(source: source(1)), second = try project(source: source(5))
        defer { try? FileManager.default.removeItem(at: first); try? FileManager.default.removeItem(at: second) }
        let a = try EditorCommunityPlayerSession(directory: first, gameID: gameID, apiVersion: 2)
        let b = try EditorCommunityPlayerSession(directory: second, gameID: gameID, apiVersion: 2)
        #expect(throws: EditorCommunityPackageManifest.Failure.self) { try EditorCommunityPlayerSession(directory: first, gameID: gameID) }
        for (session, count) in [(a, 1), (b, 5)] {
            var app = AppWorlds(main: World(name: "Scoped scriptable"))
            session.configure(&app)
            try await app.build()
            try await app.withExecutionContext {
                let script = try ScriptableObjectRegistry.make(named: "ugc.counter")
                app.main.spawn { ScriptableComponents(scripts: [script]) }
                await app.main.runScheduler(.update)
                let data = try JSONEncoder().encode(ScriptableComponents(scripts: [script]))
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                let scripts = try #require(object["scripts"] as? [[String: Any]])
                let payload = try #require(scripts.first?["payload"] as? [String: Any])
                #expect(payload["count"] as? Int == count)
                #expect(session.diagnostics.isEmpty)
            }
            ScriptableObjectRegistry.removeScope(app.executionID)
        }
        #expect(ScriptableObjectRegistry.descriptor(named: "ugc.counter") == nil)
    }

    @Test func scriptableInfiniteLifecycleStops() async throws {
        let root = try project(source: "@scriptable(id: \"ugc.bad\") class Bad { func update(context) { while (true) {} } }")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try EditorCommunityPlayerSession(directory: root, gameID: gameID, apiVersion: 2)
        var app = AppWorlds(main: World(name: "Scriptable watchdog"))
        session.configure(&app); try await app.build()
        try await app.withExecutionContext {
            let script = try ScriptableObjectRegistry.make(named: "ugc.bad")
            app.main.spawn { ScriptableComponents(scripts: [script]) }
            await app.main.runScheduler(.update)
            #expect(session.diagnostics.contains { $0.contains("execution limit") })
        }
        ScriptableObjectRegistry.removeScope(app.executionID)
    }

    @Test func preparationUsesGameAssetScope() throws {
        let root = try project(source: "")
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try EditorCommunityPlayerSession(directory: root, gameID: gameID)
        AppWorldsExecutionContext.$currentID.withValue(session.preparationScopeID) {
            #expect(AssetsManager.resolveAssetURL(at: "@res://marker.png") == root.appendingPathComponent("Assets/marker.png"))
            #expect(AssetsManager.resolveAssetURL(at: "/tmp/outside.png").lastPathComponent == ".denied")
        }
    }

    @Test func modelDependenciesAnd3DPlugins() throws {
        let root = try project(source: "", preset: .game3D)
        defer { try? FileManager.default.removeItem(at: root) }
        let assets = root.appendingPathComponent("Assets")
        var data = Data()
        for value: Float in [0, 0, 0, 1, 0, 0, 0, 1, 0] {
            var bits = value.bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
        }
        try data.write(to: assets.appendingPathComponent("mesh.bin"))
        let model = """
        {"asset":{"version":"2.0"},"buffers":[{"uri":"mesh.bin","byteLength":36}],"bufferViews":[{"buffer":0,"byteLength":36}],"accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3"}],"meshes":[{"primitives":[{"attributes":{"POSITION":0}}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}]}
        """
        let file = assets.appendingPathComponent("model.gltf")
        try model.write(to: file, atomically: true, encoding: .utf8)
        let session = try EditorCommunityPlayerSession(directory: root, gameID: gameID, apiVersion: 2)
        #expect(session.artifact.plugins.contains(.core3D))
        #expect(session.artifact.plugins.contains(.model3D))
        for bad in ["../outside.bin", "%2e%2e/outside.bin", "https://other.example.com/mesh.bin"] {
            try model.replacingOccurrences(of: "mesh.bin", with: bad).write(to: file, atomically: true, encoding: .utf8)
            #expect(throws: (any Error).self) { try EditorCommunityModelAssets.validate(in: root) }
        }
    }

    @Test func modelHierarchyLimitDoesNotDependOnNodeOrder() throws {
        let root = try project(source: "", preset: .game3D)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Assets/deep.gltf")
        let nodes: [[String: Any]] = (0..<140).map { index in
            index == 0 ? [:] : ["children": [index - 1]]
        }
        let data = try JSONSerialization.data(withJSONObject: ["asset": ["version": "2.0"], "nodes": nodes])
        try data.write(to: file)
        #expect(throws: EditorCommunityPackageManifest.Failure.self) { try EditorCommunityModelAssets.validate(in: root) }
    }

    @Test func authored3DSceneRunsAttachedGameplay() async throws {
        let source = """
        @scriptable(id: "ugc.spinning-cube")
        class Spinner {
            @export var ticks = 0;
            @component(required: true) var transform: Transform;
            func update(context) {
                ticks += 1;
                transform.rotation = [0, Math.sin(ticks * 0.01), 0, Math.cos(ticks * 0.01)];
            }
        }
        """
        let root = try project(source: source, preset: .game3D)
        var metadata = try ProjectSystem.loadProject(at: root)
        metadata.runtime.entry.scene = "Assets/Main.ascn"
        try ProjectSystem.saveProject(metadata, at: root)
        var scene = EditorSceneModel(scene: .init(id: "ugc-cube", name: "UGC 3D World"), entities: [])
        let sceneCamera = scene.addEntity(template: .camera3D, parentID: nil)
        // The engine's perspective projection is left-handed (+Z forward).
        let cameraIndex = try #require(scene.entities.firstIndex { $0.id == sceneCamera.id })
        scene.entities[cameraIndex].components[EditorBuiltInComponentType.transform]?["rotation"] = .array([.double(0), .double(1), .double(0), .double(0)])
        let cube = scene.addEntity(template: .model3D, parentID: nil)
        _ = scene.addEntity(template: .directionalLight3D, parentID: nil)
        let support = try EditorScriptableObjectCatalogLoader.load(project: metadata, at: root)
        scene.addScriptableObject(try #require(support.descriptors.first), to: cube.id)
        try scene.encodedYAML().write(to: root.appendingPathComponent("Assets/Main.ascn"), atomically: true, encoding: .utf8)
        let session = try EditorCommunityPlayerSession(directory: root, gameID: gameID, apiVersion: 2)
        var app = AppWorlds(main: World(name: "UGC 3D runtime"))
        session.configure(&app)
        app.updateScheduler = .postUpdate
        app.insertResource(PrimaryWindowId(windowId: RID()))
        app.insertResource(OffscreenRenderWorld())
        app.insertResource(DeltaTime(deltaTime: 0.016))
        try await app.build()
        try await app.update()
        let camera = try #require(app.main.getEntityByName("Camera 3D"))
        #expect(camera.components[GlobalTransform.self]?.matrix.w.z == 5)
        let render = try #require(app.getSubworldBuilder(by: .renderWorld))
        #expect(render.main.getResource(ExtractedMesh3DSources.self)?.meshes.count == 1)
        await app.withExecutionContext { await app.main.runScheduler(.update) }
        #expect(session.diagnostics.isEmpty, Comment(rawValue: session.diagnostics.joined(separator: "\n")))
        let entity = try #require(app.main.getEntityByName("Model Entity 3D"))
        #expect(app.main.get(ScriptableComponents.self, from: entity.id)?.scripts.count == 1)
        #expect(entity.components[Mesh3DComponent.self] != nil)
        ScriptableObjectRegistry.removeScope(app.executionID)
        // Keep the test-owned project for Simulator QA, outside application sources.
        try root.path.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("ada-ugc-v2-scene-path.txt"), atomically: true, encoding: .utf8)
    }

    @Test func sceneViewUsesAuthoredPerspectiveCameras() async throws {
        let root = try project(source: "", preset: .game3D)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try EditorCommunityPlayerSession(directory: root, gameID: gameID, apiVersion: 2)
        let coordinator = SceneViewCoordinator(useSceneCameras: true, make: { app in
            session.configure(&app)
            var camera = Camera()
            camera.projection = .perspective(PerspectiveProjection())
            app.main.spawn("GameCamera") { camera; Transform(position: [0, 0, 5]) }
            var inactive = camera; inactive.isActive = false
            app.main.spawn("DisabledCamera") { inactive }
        }, updateContent: { _, _ in })
        defer { coordinator.shutdown() }
        coordinator.bootstrapIfNeeded()
        for _ in 0..<500 where coordinator.appWorlds == nil { await Task.yield() }
        let app = try #require(coordinator.appWorlds)
        coordinator.updateSize(SizeInt(width: 64, height: 128), scaleFactor: 1)
        let entity = try #require(app.main.getEntityByName("GameCamera"))
        let camera = try #require(entity.components[Camera.self])
        if case .perspective = camera.projection {} else { Issue.record("Game camera projection was replaced") }
        guard case let .texture(handle) = camera.renderTarget else { Issue.record("Game camera has no offscreen target"); return }
        #expect(handle.asset.width == 64 && handle.asset.height == 128)
        #expect(app.main.getEntityByName("SceneView_Camera") == nil)
        #expect(app.main.getEntityByName("DisabledCamera")?.components[Camera.self]?.isActive == false)
        let poolSize = max(3, unsafe RenderEngine.configurations.maxFramesInFlight + 2)
        for _ in 0...poolSize { coordinator.tick(0.016) }
        let exhausted = try #require(entity.components[Camera.self])
        #expect(exhausted.isActive)
        if case .window(.primary) = exhausted.renderTarget {} else { Issue.record("Exhausted viewport reused a pending render target") }
    }

    @Test func multiplayerStartsSoloAndHostJoinUseBoundRelease() async throws {
        let root = try project(source: "", multiplayer: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let session = try EditorCommunityPlayerSession(directory: root, gameID: gameID, releaseID: buildID, apiVersion: 2)
        #expect(session.network?.configuration.compatibility.gameIdentifier == gameID)
        var app = AppWorlds(main: World(name: "UGC solo multiplayer"))
        session.configure(&app)
        try await app.build()
        #expect(app.main.getResource(AdaScriptMultiplayerState.self) != nil)
        #expect(app.main.getResource(MultiplayerSession.self) != nil)
        if let connection = app.main.getResource(MultiplayerSession.self) { await connection.stop() }
        ScriptableObjectRegistry.removeScope(app.executionID)
        let server = try #require(URL(string: "https://cloud.example.com"))
        let gameID = self.gameID, buildID = self.buildID
        let client = EditorCommunityMultiplayerClient(server: server, api: { path, body, authenticated in
            #expect(body["gameID"].string == gameID); #expect(body["buildID"].string == buildID)
            #expect(authenticated == (path == "/multiplayer/sessions"))
            return ["sessionID": .string(UUID().uuidString), "peerID": .string(UUID().uuidString), "joinCode": "ABCDEFGH", "relayURL": "wss://relay.example.com/v1/multiplayer/connect", "connectionTicket": "opaque-ticket", "expiresAt": .number(Date().timeIntervalSince1970 + 60), "gameID": .string(gameID), "buildID": .string(buildID)]
        })
        #expect(try await client.create(gameID: gameID, buildID: buildID).role == .host)
        #expect(try await client.join(code: "abcdefgh", gameID: gameID, buildID: buildID).role == .peer)
        let mismatched = EditorCommunityMultiplayerClient(server: server, api: { _, _, _ in
            ["gameID": "different", "buildID": .string(buildID)]
        })
        await #expect(throws: EditorCommunityMultiplayerError.self) { try await mismatched.join(code: "ABCDEFGH", gameID: gameID, buildID: buildID) }
    }
}
