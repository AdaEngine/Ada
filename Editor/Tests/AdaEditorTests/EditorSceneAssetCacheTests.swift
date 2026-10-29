@_spi(Internal) import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Synchronization
import Testing

@testable import AdaEditor

@MainActor
@Suite("Preview asset ownership", .serialized)
struct EditorSceneAssetCacheTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("Repeated references and scene reloads import once; removed assets are released")
    func repeatedReferences() async throws {
        let root = try directory()
        let counter = ImportCounter()
        GLTFLoaderResolver.shared.setLoader(CountingLoader(counter: counter))
        defer { try? FileManager.default.removeItem(at: root); GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader()) }
        let source = try modelFile(in: root)
        let scene = sceneModel(source: source.lastPathComponent, count: 3)
        let world = World()
        let url = root.appendingPathComponent("Main.ascn")
        let first = EditorSceneFileLoader.load(model: scene, into: world, sourceURL: url, resourceRootURL: root)
        #expect(first.warnings.isEmpty)
        #expect(counter.value.withLock { $0 } == 1)
        var retained = world.getResource(EditorSceneAssetCache.self)
        weak var asset = retained?.models.values.first?.asset
        #expect(asset != nil)
        retained = nil
        for id in first.entitiesByEditorID.values { world.removeEntity(id, recursively: true) }
        world.flush()
        let second = EditorSceneFileLoader.load(model: scene, into: world, sourceURL: url, resourceRootURL: root)
        #expect(second.warnings.isEmpty)
        #expect(counter.value.withLock { $0 } == 1)
        for id in second.entitiesByEditorID.values { world.removeEntity(id, recursively: true) }
        world.flush()
        _ = EditorSceneFileLoader.load(model: sceneModel(source: nil, count: 1), into: world)
        #expect(world.getResource(EditorSceneAssetCache.self)?.models.isEmpty == true)
        #expect(asset == nil)
    }

    @Test("The editing viewport imports asynchronously and ignores a closed viewport's result")
    func responsiveViewportAndCancellation() async throws {
        let root = try directory()
        let counter = ImportCounter()
        GLTFLoaderResolver.shared.setLoader(CountingLoader(counter: counter, delay: true))
        defer { try? FileManager.default.removeItem(at: root); GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader()) }
        let source = try modelFile(in: root)
        let model = sceneModel(source: source.lastPathComponent, count: 2)
        let viewport = EditorSceneViewportModel()
        viewport.configure(sceneContent: "fixture", model: model, sourceURL: root.appendingPathComponent("Main.ascn"),
                           resourceRootURL: root, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        let world = World()
        var finished: EditorSceneRuntimeLoadResult?
        viewport.loadSceneWorld(world, onLoadingChanged: { _ in }, onLoaded: { finished = $0 })
        try await Task.sleep(for: .milliseconds(30))
        #expect(finished == nil, "The main actor must run while the importer is still waiting")
        for _ in 0..<100 where finished == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(finished?.warnings.isEmpty == true)
        #expect(finished?.entitiesByEditorID.count == 2)
        #expect(counter.value.withLock { $0 } == 1)
        viewport.disconnect()

        let closed = EditorSceneViewportModel()
        closed.configure(sceneContent: "fixture", model: model, sourceURL: root.appendingPathComponent("Main.ascn"),
                         resourceRootURL: root, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        var staleCallback = false
        let abandoned = World()
        closed.loadSceneWorld(abandoned, onLoadingChanged: { _ in }, onLoaded: { _ in staleCallback = true })
        closed.disconnect()
        try await Task.sleep(for: .milliseconds(250))
        #expect(!staleCallback)
        #expect(abandoned.getResource(EditorSceneAssetCache.self) == nil)
    }

    @Test("Models share identical imported textures; color interpretation and samplers stay distinct")
    func sharedTextures() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let png = try Image(width: 2, height: 2, color: .red).pngData()
        func load(_ name: String, wrap: Int = 10497, image: Data? = nil) async throws -> AssetHandle<ModelAsset3D> {
            let url = root.appendingPathComponent(name + ".gltf")
            let document: [String: Any] = [
                "asset": ["version": "2.0"], "scenes": [["nodes": []]],
                "images": [["uri": "data:image/png;base64," + (image ?? png).base64EncodedString()]],
                "samplers": [["wrapS": wrap]], "textures": [["source": 0, "sampler": 0]],
                "materials": [["pbrMetallicRoughness": ["baseColorTexture": ["index": 0]], "normalTexture": ["index": 0]]]
            ]
            try JSONSerialization.data(withJSONObject: document).write(to: url)
            return try await AssetsManager.load(ModelAsset3D.self, at: url.path)
        }
        let a = try await load("A")
        let b = try await load("B")
        let c = try await load("C", wrap: 33071)
        let first = try #require(a.asset.materials.first as? PBRMaterial)
        let second = try #require(b.asset.materials.first as? PBRMaterial)
        let clamped = try #require(c.asset.materials.first as? PBRMaterial)
        #expect(first !== second)
        #expect(first.baseColorTexture != nil)
        #expect(first.baseColorTexture === second.baseColorTexture)
        #expect(first.normalTexture === second.normalTexture)
        #expect(first.baseColorTexture !== first.normalTexture)
        #expect(first.baseColorTexture !== clamped.baseColorTexture)
        let changed = try await load("Changed", image: Image(width: 2, height: 2, color: .blue).pngData())
        let edited = try #require(changed.asset.materials.first as? PBRMaterial)
        #expect(first.baseColorTexture !== edited.baseColorTexture)
        weak var released: Texture2D?
        do {
            let ephemeral = try await load("Ephemeral", image: Image(width: 2, height: 2, color: .green).pngData())
            let material = try #require(ephemeral.asset.materials.first as? PBRMaterial)
            released = material.baseColorTexture
            #expect(released != nil)
        }
        #expect(released == nil, "The shared texture index must not retain a GPU texture after its owners disappear")
    }

    @Test("Replacing a scene during entity installation removes every cancelled entity")
    func replacePartiallyInstalledScene() async throws {
        var large = sceneModel(source: nil, count: 5_000)
        for index in large.entities.indices {
            large.entities[index].components[EditorBuiltInComponentType.transform] =
                EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
        }
        let viewport = EditorSceneViewportModel()
        viewport.configure(sceneContent: "large", model: large, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        let world = World()
        let application = AppWorlds(main: world)
        var loaded: [EditorSceneRuntimeLoadResult] = []
        viewport.loadSceneWorld(world, application: application, onLoadingChanged: { _ in }, onLoaded: { loaded.append($0) })
        for _ in 0..<1_000 where world.getEntities().isEmpty { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!world.getEntities().isEmpty)
        #expect(loaded.isEmpty, "The replacement must interrupt a partially installed scene")
        var replacement = sceneModel(source: nil, count: 1)
        replacement.entities[0].id = "replacement"
        viewport.configure(sceneContent: "replacement", model: replacement, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        for _ in 0..<1_000 where loaded.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
        #expect(loaded.count == 1)
        #expect(loaded.first?.entitiesByEditorID.keys.sorted() == ["replacement"])
        #expect(world.getEntities().count == 1)
        viewport.disconnect()
    }

    @Test("A changed model file is reimported and a broken model does not block the other entities")
    func changedAndBrokenFiles() async throws {
        let root = try directory()
        let counter = ImportCounter()
        GLTFLoaderResolver.shared.setLoader(CountingLoader(counter: counter))
        defer { try? FileManager.default.removeItem(at: root); GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader()) }
        let source = try modelFile(in: root)
        let url = root.appendingPathComponent("Main.ascn")
        let scene = sceneModel(source: source.lastPathComponent, count: 2)
        let first = try await EditorSceneAssetCache.prepare(model: scene, sourceURL: url, resourceRootURL: root)
        let edited = try String(contentsOf: source, encoding: .utf8).replacingOccurrences(of: "Imported", with: "Replacement node")
        try edited.write(to: source, atomically: true, encoding: .utf8)
        let replacement = try await EditorSceneAssetCache.prepare(model: scene, sourceURL: url, resourceRootURL: root, reusing: first)
        #expect(replacement.models.values.first?.asset.nodes.first?.name == "Replacement node")
        #expect(counter.value.withLock { $0 } == 2)
        try "invalid model".write(to: source, atomically: true, encoding: .utf8)
        let broken = try await EditorSceneAssetCache.prepare(model: scene, sourceURL: url, resourceRootURL: root, reusing: replacement)
        let world = World()
        world.insertResource(broken)
        let result = EditorSceneFileLoader.load(model: scene, into: world, sourceURL: url, resourceRootURL: root)
        #expect(result.entitiesByEditorID.count == 2)
        #expect(result.warnings.count == 2)
        #expect(counter.value.withLock { $0 } == 3, "Installation reports the prepared error without retrying the broken import on the UI actor")
    }

    @Test("Open a selected large scene through the editing viewport", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_PREVIEW_BENCHMARK"] != nil))
    func realPreviewBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ADAEDITOR_PREVIEW_BENCHMARK"])
        let url = URL(fileURLWithPath: path)
        let assets = url.deletingLastPathComponent().deletingLastPathComponent()
        let counter = ImportCounter()
        GLTFLoaderResolver.shared.setLoader(CountingLoader(counter: counter))
        defer { GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader()) }
        let start = ContinuousClock.now
        var ticks = 0
        var gap = Duration.zero
        var previous = start
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(20))
                let now = ContinuousClock.now
                gap = max(gap, previous.duration(to: now))
                previous = now
                ticks += 1
            }
        }
        defer { ticker.cancel() }
        let item = EditorProjectSidebarViewModel.Item(id: url.path, disclosure: "", icon: "", title: url.lastPathComponent,
                                                     relativePath: url.lastPathComponent, level: 0, isActive: false, isFolder: false, kind: .scene)
        let document = EditorViewModel.document(for: item)
        let requested = ContinuousClock.now
        let workbench = EditorWorkbenchViewModel(openDocuments: [document], activeDocumentID: document.id)
        for _ in 0..<3_000 where workbench.activeSceneDocument?.isLoading == true {
            try await Task.sleep(for: .milliseconds(20))
        }
        let loaded = try #require(workbench.activeSceneDocument)
        let model = try #require(loaded.sceneModel)
        let decoded = ContinuousClock.now
        let viewport = EditorSceneViewportModel()
        let world = World()
        viewport.configure(sceneContent: loaded.content, model: model, sourceURL: url, resourceRootURL: assets,
                           onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        defer { viewport.disconnect() }
        let result = await withCheckedContinuation { continuation in
            viewport.loadSceneWorld(world, onLoadingChanged: { _ in }, onLoaded: { continuation.resume(returning: $0) })
        }
        let finished = ContinuousClock.now
        gap = max(gap, previous.duration(to: finished))
        #expect(result.entitiesByEditorID.count == model.entities.count)
        #expect(!result.warnings.contains { $0.hasPrefix("Failed to load model") || $0.hasPrefix("Failed to load Spine") })
        #expect(ticks > 0)
        #expect(gap < .seconds(2), "Installation must not freeze the UI for several seconds")
        let cache = try #require(world.getResource(EditorSceneAssetCache.self))
        #expect(counter.value.withLock { $0 } == cache.models.count)
        let report: [String: Any] = [
            "scene": path, "documentRequestSeconds": seconds(start.duration(to: requested)),
            "decodeSeconds": seconds(start.duration(to: decoded)),
            "previewSeconds": seconds(start.duration(to: finished)), "maximumMainActorGapSeconds": seconds(gap),
            "mainActorTicks": ticks, "authoredEntities": result.entitiesByEditorID.count,
            "runtimeEntities": result.entityCount, "modelImports": counter.value.withLock { $0 },
            "retainedModels": cache.models.count, "warnings": result.warnings,
            "scope": "Production file/document/decode and editing viewport load with the headless renderer; GPU presentation is checked separately"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let output = ProcessInfo.processInfo.environment["ADAEDITOR_PREVIEW_BENCHMARK_REPORT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

    @Test("Editing keeps collider data in the document while Play installs physics bodies")
    func previewPhysicsOwnership() async throws {
        var model = sceneModel(source: nil, count: 1)
        model.entities[0].components[EditorBuiltInComponentType.physicsBody3D] =
            EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.physicsBody3D)
        let viewport = EditorSceneViewportModel()
        viewport.configure(sceneContent: "physics fixture", model: model, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
        let preview = World()
        var result: EditorSceneRuntimeLoadResult?
        viewport.loadSceneWorld(preview, onLoadingChanged: { _ in }, onLoaded: { result = $0 })
        let id = try #require(result?.entitiesByEditorID["0"])
        #expect(preview.getEntityByID(id)?.components[PhysicsBody3DComponent.self] == nil)
        #expect(viewport.sceneModel?.entities[0].components[EditorBuiltInComponentType.physicsBody3D] != nil)
        let play = World()
        let played = EditorSceneFileLoader.load(model: model, into: play)
        let playID = try #require(played.entitiesByEditorID["0"])
        #expect(play.getEntityByID(playID)?.components[PhysicsBody3DComponent.self] != nil)
        viewport.disconnect()
    }

    @Test("Fast JSON scenes preserve the typed envelope and every entity's component values")
    func sceneJSONParity() throws {
        var model = sceneModel(source: nil, count: 2)
        model.entities[0].components["fixture.large-values"] = [
            "values": .array([.null, .bool(true), .int(-12), .uint(.max), .double(1.25), .string("true"),
                              .object(["vector": .array([.double(0), .double(-0.25)])])])
        ]
        model.entities[1].components["fixture.other"] = ["title": .string("Осень"), "enabled": .bool(false)]
        let data = try JSONEncoder().encode(model)
        let fast = try EditorSceneModel.decode(from: String(decoding: data, as: UTF8.self))
        let conventional = try JSONDecoder().decode(EditorSceneModel.self, from: data)
        #expect(fast == conventional)
    }

    @Test("A real large document opens without decoding on the UI actor and closing cancels installation")
    func responsiveDocumentOpen() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        var model = sceneModel(source: nil, count: 1)
        model.entities[0].components["fixture.geometry"] = ["vertices": .array((0..<30_000).map {
            .object(["x": .double(Double($0) * 0.01), "y": .double(0), "z": .double(-0.25)])
        })]
        let url = root.appendingPathComponent("Main.ascn")
        try JSONEncoder().encode(model).write(to: url)
        let item = EditorProjectSidebarViewModel.Item(id: url.path, disclosure: "", icon: "", title: url.lastPathComponent,
                                                     relativePath: "Main.ascn", level: 0, isActive: false, isFolder: false, kind: .scene)
        let start = ContinuousClock.now
        guard case let .scene(document) = EditorViewModel.document(for: item) else { Issue.record("Expected a scene document"); return }
        #expect(start.duration(to: .now) < .milliseconds(500))
        #expect(document.isLoading)
        #expect(document.sceneModel == nil)
        #expect(EditorAgentSceneContext(document: document)?.selectedEntityID == nil)
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        #expect(workbench.saveSceneDocument(id: document.id))
        var edits = 0
        workbench.onDocumentEdited = { _ in edits += 1 }
        var ticks = 0
        for _ in 0..<1_000 where workbench.activeSceneDocument?.isLoading == true {
            try await Task.sleep(for: .milliseconds(10))
            ticks += 1
        }
        #expect(ticks > 0)
        #expect(workbench.activeSceneDocument?.sceneModel?.entities.count == 1)
        #expect(workbench.activeSceneDocument?.errorMessage == nil)
        #expect(workbench.activeSceneDocument?.isLoading == false)
        #expect(edits == 0)
        #expect(workbench.sceneUndoHistory[document.id] == nil)
        workbench.open(.scene(document))
        workbench.closeDocument(id: document.id)
        try await Task.sleep(for: .milliseconds(50))
        #expect(workbench.openDocuments.isEmpty)
    }

    private func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Preview assets \(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func modelFile(in root: URL) throws -> URL {
        let url = root.appendingPathComponent("Model.gltf")
        try """
        {"asset":{"version":"2.0"},"nodes":[{"name":"Imported"}],"scenes":[{"nodes":[0]}],"scene":0}
        """.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func sceneModel(source: String?, count: Int) -> EditorSceneModel {
        EditorSceneModel(scene: EditorSceneMetadata(id: "fixture", name: "Preview"), entities: (0..<count).map { index in
            EditorSceneEntity(id: "\(index)", name: "Owner \(index)", enabled: true, parent: nil,
                              components: source.map { [EditorBuiltInComponentType.model3DSource: ["source": .string($0)]] } ?? [:])
        })
    }

    private final class ImportCounter: Sendable {
        let value = Mutex(0)
    }

    private struct CountingLoader: GLTFLoader {
        let counter: ImportCounter
        var delay = false
        func load(url: URL) async throws -> GLTFImportResult {
            counter.value.withLock { $0 += 1 }
            if delay { try await Task.sleep(for: .milliseconds(150)) }
            return try await NativeGLTFLoader().load(url: url)
        }
    }
}
