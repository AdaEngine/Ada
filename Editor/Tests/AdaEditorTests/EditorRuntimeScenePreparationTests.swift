@_spi(Internal) @testable import AdaRender
@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Responsive scene preparation", .serialized)
struct EditorRuntimeScenePreparationTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("A pending model import leaves the main actor responsive and is reused by instantiation")
    func asyncImportAndStrongCacheLifetime() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Scene preparation \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root); GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader()) }
        let url = root.appendingPathComponent("Main.ascn")
        try """
        {"asset":{"version":"2.0"},"nodes":[{"name":"Prepared model"}],"scenes":[{"nodes":[0]}],"scene":0}
        """.write(to: root.appendingPathComponent("Model.gltf"), atomically: true, encoding: .utf8)
        var model = EditorSceneModel.default(projectName: "Responsive loading")
        for i in 0..<2 {
            let entity = model.addEntity(name: "Owner \(i)")
            let index = try #require(model.entities.firstIndex { $0.id == entity.id })
            model.entities[index].components[EditorBuiltInComponentType.model3DSource] = ["source": .string("@res://Model.gltf")]
        }
        try JSONEncoder().encode(model).write(to: url)
        let counter = ImportCounter();GLTFLoaderResolver.shared.setLoader(DelayedLoader(counter: counter))
        var heartbeat = false
        let loading = Task { try await EditorRuntimeScenePreparation.prepare(at: url, assetsDirectory: root) }
        let tick = Task { @MainActor in
            try await Task.sleep(for: .milliseconds(20))
            heartbeat = true
        }
        let prepared = try await loading.value
        #expect(heartbeat, "The main actor must run while the model importer is suspended")
        try await tick.value
        #expect(await counter.count == 1, "Shared model references are imported once")
        let result = withExtendedLifetime(prepared) {
            EditorSceneFileLoader.load(model: prepared.model, into: World(), sourceURL: url, resourceRootURL: root)
        }
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        #expect(await counter.count == 1, "The synchronous installation must hit the held asset cache")
    }

    @Test("JSON mesh payloads retain their data and YAML flow mappings still load")
    func largeJSONAndYAMLFallback() throws {
        var model = EditorSceneModel.default(projectName: "Large JSON")
        let vertices = (0..<30_000).map { EditorSceneValue.object(["x": .double(Double($0) * 0.01), "y": .double(0), "z": .double(-0.25)]) }
        model.entities[0].components["fixture.large-mesh"] = ["vertices": .array(vertices)]
        let content = String(decoding: try JSONEncoder().encode(model), as: UTF8.self)
        let clock = ContinuousClock();let start = clock.now
        let decoded = try EditorSceneModel.decode(from: content)
        let elapsed = start.duration(to: clock.now)
        print("JSON mesh scene decode, \(content.utf8.count) bytes: \(elapsed)")
        #expect(decoded.entities[0].components["fixture.large-mesh"]?["vertices"]?.array.count == vertices.count)
        #expect(decoded.scene == model.scene)
        #expect(elapsed < .seconds(10))
        let flow = try EditorSceneModel.decode(from: "{format: ada.scene, schemaVersion: 1, scene: {id: test, name: YAML}, entities: []}")
        #expect(flow.scene.name == "YAML")
    }

    @Test("A nested scene cycle fails during preparation")
    func nestedCycle() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        var model = EditorSceneModel.default(projectName: "Cycle")
        model.entities[0].components[EditorBuiltInComponentType.sceneInstance] = ["scene": .string("@res://Main.ascn")]
        let url = root.appendingPathComponent("Main.ascn");try JSONEncoder().encode(model).write(to: url)
        await #expect(throws: (any Error).self) { try await EditorRuntimeScenePreparation.prepare(at: url, assetsDirectory: root) }
    }

    @Test("Prepare an explicitly selected large project scene", .enabled(if: ProcessInfo.processInfo.environment["ADAEDITOR_SCENE_BENCHMARK"] != nil))
    func realScenePreparationBenchmark() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["ADAEDITOR_SCENE_BENCHMARK"])
        let scene = URL(fileURLWithPath: path)
        let assets = scene.deletingLastPathComponent().deletingLastPathComponent()
        let heartbeat = Heartbeat()
        let ticker = Task { @MainActor in
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(20))
                heartbeat.tick()
            }
        }
        defer { ticker.cancel() }
        let start = ContinuousClock.now
        let prepared = try await EditorRuntimeScenePreparation.prepare(at: scene, assetsDirectory: assets)
        let elapsed = start.duration(to: .now)
        #expect(heartbeat.count > 0)
        #expect(heartbeat.maximumGap < .seconds(2), "Large scene decoding/import must not block the main actor")
        #expect(!prepared.model.entities.isEmpty)
        let report: [String: Any] = [
            "scene": path, "status": "passed", "preparationSeconds": elapsed.seconds,
            "mainActorTicks": heartbeat.count, "maximumMainActorGapSeconds": heartbeat.maximumGap.seconds,
            "authoredEntities": prepared.model.entities.count,
            "scope": "Actual scene/model/texture preparation with the native headless renderer; no visible game/FPS acceptance"
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        print(String(decoding: data, as: UTF8.self))
        if let output = ProcessInfo.processInfo.environment["ADAEDITOR_SCENE_BENCHMARK_REPORT"] {
            try data.write(to: URL(fileURLWithPath: output))
        }
    }

    @MainActor private final class Heartbeat {
        var count = 0
        var maximumGap = Duration.zero
        private var previous = ContinuousClock.now
        func tick() {
            let now = ContinuousClock.now
            maximumGap = max(maximumGap,previous.duration(to: now));previous = now;count += 1
        }
    }

    private actor ImportCounter {
        var count = 0
        func increment() { count += 1 }
    }

    private struct DelayedLoader: GLTFLoader {
        let counter: ImportCounter
        func load(url: URL) async throws -> GLTFImportResult {
            await counter.increment()
            try await Task.sleep(for: .milliseconds(150))
            return try await NativeGLTFLoader().load(url: url)
        }
    }
}

private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
