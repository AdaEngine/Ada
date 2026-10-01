#if canImport(GravityAOT)
import AdaAnimation
@_spi(Internal) @testable import AdaApp
@testable import AdaAssets
@_spi(Scripting) import AdaECS
import AdaInput
import AdaMultiplayer
import AdaRender
import AdaScene
import AdaScriptAOTFixture
import AdaTransform
@testable import AdaScripting
import Foundation
import GravityAOT
import Testing

@Suite("Native AdaScript host adapters", .serialized)
struct AdaScriptNativeAdapterTests {
    private var sources: [AdaScriptSource] {
        get throws {
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("AdaScriptAOTFixture/HostAdapters.ada")
            return [AdaScriptSource(path: url.lastPathComponent, source: try String(contentsOf: url, encoding: .utf8))]
        }
    }

    @Test("Native commands spawn through the deferred queue and round-trip through multiplayer")
    @MainActor
    func nativeNetworkAndCommands() async throws {
        let hub = InMemoryTransportHub()
        let sessionID = SessionID()
        let compatibility = NetworkCompatibility(gameIdentifier: "native-adapters", buildIdentifier: "1")
        let peerID = PeerID()
        func make(_ role: NetworkRole) async throws -> (AppWorlds, AdaScriptNativePlugin) {
            let world = World(name: "Native \(role)")
            let app = AppWorlds(main: world)
            let pointer = try #require(ada_native_hosts_get_module())
            let runtime = unsafe try NativeModule(module: pointer)
            let plugin = try AdaScriptNativePlugin(module: runtime, name: "Native \(role)", sources: sources)
            app.addPlugin(InputPlugin())
                .addPlugin(
                    MultiplayerPlugin(
                        configuration: MultiplayerConfiguration(role: role, sessionID: sessionID, localPeerID: role == .peer ? peerID : PeerID(), compatibility: compatibility),
                        transport: InMemoryTransport(hub: hub)
                    )
                )
                .addPlugin(plugin)
            try await app.build()
            #expect(plugin.diagnostics.isEmpty)
            return (app, plugin)
        }
        let (host, hostPlugin) = try await make(.host)
        let (peer, peerPlugin) = try await make(.peer)
        for _ in 0..<3 {
            await host.main.runScheduler(.networkReceive)
            await peer.main.runScheduler(.networkReceive)
        }
        await peer.main.runScheduler(.update)
        #expect(peerPlugin.diagnostics.isEmpty)
        let spawned = try #require(peer.main.getResource(AdaScriptNativeResources.self)?.values["aot.host.capture"]?["spawned"])
        guard case .int(let id) = spawned else {
            Issue.record("No native spawn ID")
            return
        }
        peer.main.flush()
        let descriptor = try #require(peer.main.runtimeComponentDescriptor(named: "HostPosition"))
        #expect(peer.main.readComponentField(component: descriptor.componentID, entity: id, field: descriptor.fields[0]) == .double(5))
        await peer.main.runScheduler(.networkSend)
        await host.main.runScheduler(.networkReceive)
        await host.main.runScheduler(.update)
        #expect(hostPlugin.diagnostics.isEmpty)
        #expect(host.main.getResource(AdaScriptNativeResources.self)?.values["aot.host.capture"]?["amount"] == .int(27))
        #expect(host.main.getResource(AdaScriptNativeResources.self)?.values["aot.host.capture"]?["asyncAmount"] == .int(0))
        await host.main.runScheduler(.update)
        #expect(host.main.getResource(AdaScriptNativeResources.self)?.values["aot.host.capture"]?["asyncAmount"] == .int(41))
        #expect(host.main.getResource(AdaScriptNativeResources.self)?.values["aot.host.capture"]?["sender"] == .string(peerID.rawValue.uuidString))
        #expect(hostPlugin.diagnostics.isEmpty)
    }

    @Test("Borrowed world and Input capabilities reject use after callback lifetime")
    @MainActor
    func staleCapabilities() throws {
        let pointer = try #require(ada_native_hosts_get_module())
        let module = unsafe try NativeModule(module: pointer)
        let world = World()
        let scope = NativeCallbackScope()
        let host = NativeWorldHost(scope: scope, commands: Commands(entities: world.entities, commandsQueue: world.commandQueue), navigator: nil, components: [], module: module)
        scope.isActive = false
        #expect(throws: AdaScriptError.self) { try host.call("spawn", arguments: [.list([])]) }
    }

    @Test("Native asset calls retain typed handles and save through AdaAssets")
    @MainActor
    func nativeAssets() async throws {
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeScriptAssets-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            AssetsManager.registerAssetType(NativeScriptAsset.self)
            await AssetsManager.setProjectDirectories(
                ProjectDirectories(
                    source: root,
                    assetsDirectory: root.appendingPathComponent("Assets"),
                    userDataDirectory: root.appendingPathComponent("User"),
                    cacheDirectory: root.appendingPathComponent("Cache")
                )
            )
            try await AssetsManager.save(NativeScriptAsset(value: "native assets"), at: "@res://probe.nativeasset")
            let pointer = try #require(ada_native_hosts_get_module())
            let module = unsafe try NativeModule(module: pointer)
            let instance = try module.makeInstance(type: "HostProbe")
            let scope = NativeCallbackScope()
            let assets = NativeAssetsHost(store: NativeAssetStore(), scope: scope)
            let value = try module.invoke(instance, method: "save", arguments: [.null], globals: ["__adaAssets": .host(assets)])
            #expect(value.literal == .string("@res://probe.nativeasset"))
            let saved = try await AssetsManager.load(NativeScriptAsset.self, at: "@user://copy.nativeasset")
            #expect(saved.asset.value == "native assets")
            scope.isActive = false
            #expect(throws: AdaScriptError.self) { try assets.call("load", arguments: [.string("@res://probe.nativeasset")]) }
        }
    }

    @Test("Native async assets publish detached results after their callback scope ends")
    @MainActor
    func nativeAsyncAssets() async throws {
        try await AppWorldsExecutionContext.$currentID.withValue(UUID()) {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAsyncAsset-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: root) }
            AssetsManager.registerAssetType(NativeScriptAsset.self)
            await AssetsManager.setProjectDirectories(ProjectDirectories(source: root, assetsDirectory: root.appendingPathComponent("Assets"),
                userDataDirectory: root.appendingPathComponent("User"), cacheDirectory: root.appendingPathComponent("Cache")))
            try await AssetsManager.save(NativeScriptAsset(value: "async native asset"), at: "@res://probe.nativeasset")
            let pointer = try #require(ada_native_async_get_module())
            let module = unsafe try NativeModule(module: pointer)
            let runtime = NativeAsyncRuntime(module: module)
            let probe = try module.makeInstance(type: "NativeAsyncProbe")
            let scope = NativeCallbackScope()
            let assets = NativeAssetsHost(store: NativeAssetStore(), scope: scope, asyncRuntime: runtime)
            let globals = runtime.globals.merging(["__adaAssets": .host(assets)]) { _, value in value }
            guard case .task(let task) = try module.invoke(probe, method: "load", arguments: [.string("@res://probe.nativeasset")], globals: globals) else {
                Issue.record("Expected async asset task"); return
            }
            scope.isActive = false
            for _ in 0..<200 {
                if case .completed(let value) = try module.poll(task, globals: runtime.globals) {
                    #expect(value.literal == .string("@res://probe.nativeasset")); return
                }
                try await Task.sleep(for: .milliseconds(1))
            }
            Issue.record("Native async asset did not complete")
        }
    }

    @Test("Native scene imports expand prefabs and prepare camera render components")
    @MainActor
    func prefabsAndCamera() throws {
        Camera.registerComponent()
        SceneInstance.registerComponent()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeScenePrefab-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = AdaScriptNativeSceneDocument(
            name: "Nested",
            entities: [.init(id: "camera", name: "Camera", enabled: true, parent: nil, components: [String(reflecting: Camera.self): try JSONEncoder().encode(SceneCameraSettings(camera: Camera()))])]
        )
        let nestedURL = root.appendingPathComponent("Nested.ascn")
        try JSONEncoder().encode(nested).write(to: nestedURL)
        let document = AdaScriptNativeSceneDocument(
            name: "Root",
            entities: [
                .init(
                    id: "prefab",
                    name: "Prefab",
                    enabled: true,
                    parent: nil,
                    components: [String(reflecting: SceneInstance.self): try JSONEncoder().encode(SceneInstance(scene: "@res://Nested.ascn"))]
                )
            ]
        )
        let scene = try document.makeScene(components: [], resourceRoot: root)
        let camera = try #require(scene.world.getEntityByName("Camera"))
        #expect(scene.world.has(CameraRenderGraph.self, in: camera.id))
        #expect(scene.world.has(VisibleEntities.self, in: camera.id))
        // The same imported document must reject cycles instead of recursing forever.
        try JSONEncoder().encode(document).write(to: nestedURL)
        #expect(throws: AdaScriptError.self) { try document.makeScene(components: [], resourceRoot: root) }
    }

    @Test("Exported animation JSON runs through the scene scheduler and survives prefab expansion")
    @MainActor
    func nativeSceneAnimation() async throws {
        Transform.registerComponent()
        SceneInstance.registerComponent()
        let clip = KeyframeClip(name: "Move", initialValues: SceneTransformAnimationValues(transform: Transform()), duration: 0.1, repeatMode: .once) {
            KeyframeTrack(\.transform.position.x, identifier: "transform.position.x") {
                LinearKeyframe(Float(0), duration: 0.1)
                LinearKeyframe(Float(10), duration: 0.1)
            }
        }
        let encoded = try clip.encodeToJSONData()
        let document = AdaScriptNativeSceneDocument(name: "Animation", entities: [
            .init(id: "actor", name: "Actor", enabled: true, parent: nil,
                  components: [String(reflecting: Transform.self): try JSONEncoder().encode(Transform())], animationClips: [encoded])
        ])
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("NativeAnimation-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try JSONEncoder().encode(document).write(to: root.appendingPathComponent("Animation.ascn"))
        let prefab = AdaScriptNativeSceneDocument(name: "Prefab", entities: [
            .init(id: "prefab", name: "Prefab", enabled: true, parent: nil,
                  components: [String(reflecting: SceneInstance.self): try JSONEncoder().encode(SceneInstance(scene: "@res://Animation.ascn"))])
        ])
        let scene = try prefab.makeScene(components: [], resourceRoot: root)
        let actor = try #require(scene.world.getEntityByName("Actor"))
        scene.world.addSystem(KeyframeAnimationApplySystem.self, on: .update)
        scene.world.insertResource(DeltaTime(deltaTime: 0.05))
        await scene.world.runScheduler(.update, deltaTime: 0.05)
        #expect(abs((scene.world.get(Transform.self, from: actor.id)?.position.x ?? 0) - 5) < 0.01)
        await scene.world.runScheduler(.update, deltaTime: 0.05)
        #expect(scene.world.get(Transform.self, from: actor.id)?.position.x == 10)
        #expect(scene.world.get(KeyframeAnimator.self, from: actor.id)?.playbackState == .stopped)
        let bad = AdaScriptNativeSceneDocument(name: "Invalid", entities: [
            .init(id: "actor", name: "Actor", enabled: true, parent: nil, components: [:], animationClips: [encoded])
        ])
        #expect(throws: AdaScriptError.self) { try bad.makeScene(components: []) }
        let duplicate = AdaScriptNativeSceneDocument(name: "Invalid", entities: [
            .init(id: "actor", name: "Actor", enabled: true, parent: nil,
                  components: [String(reflecting: Transform.self): try JSONEncoder().encode(Transform())], animationClips: [encoded, encoded])
        ])
        #expect(throws: AdaScriptError.self) { try duplicate.makeScene(components: []) }
    }

    @Test("Exported scenes preserve native fields, hierarchy, and disabled entities")
    @MainActor
    func nativeSceneRoundTrip() throws {
        Transform.registerComponent()
        let descriptor = RuntimeComponentDescriptor(stableID: "position", name: "Position", fieldNames: ["value"], defaultValues: [.double(0)])
        let document = AdaScriptNativeSceneDocument(
            name: "Export proof",
            entities: [
                .init(id: "root", name: "Root", enabled: true, parent: nil, components: [:]),
                .init(id: "child", name: "Child", enabled: false, parent: "root", components: ["Position": Data("{\"value\":12.5}".utf8)]),
            ]
        )
        let detached = try JSONDecoder().decode(AdaScriptNativeSceneDocument.self, from: JSONEncoder().encode(document))
        let scene = try detached.makeScene(components: [descriptor])
        let child = try #require(scene.world.getEntityByName("Child"))
        #expect(!child.isActive)
        #expect(scene.world.readComponentField(component: descriptor.componentID, entity: child.id, field: descriptor.fields[0]) == .double(12.5))
    }
}
private final class NativeScriptAsset: Asset, @unchecked Sendable {
    var assetMetaInfo: AssetMetaInfo?
    let value: String
    init(value: String) { self.value = value }
    init(from decoder: any AssetDecoder) throws { value = try decoder.decode(String.self) }
    func encodeContents(with encoder: any AssetEncoder) throws { try encoder.encode(value) }
    static func extensions() -> [String] { ["nativeasset"] }
}
#endif
