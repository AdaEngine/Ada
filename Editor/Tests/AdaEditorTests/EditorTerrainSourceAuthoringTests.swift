@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor terrain source authoring", .serialized)
struct EditorTerrainSourceAuthoringTests {
    @Test("A source stroke saves a private version and leaves the scene's previous resource exact for Undo")
    func savedVersion() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try Data(contentsOf: fixture.file)
        let original = try #require(fixture.owner.components[Terrain3DSource.self])
        let result = try await perform(fixture, operation: .raise)
        let saved = try #require(try? result.get())
        #expect(saved != fixture.file)
        #expect(saved.deletingLastPathComponent() == fixture.file.deletingLastPathComponent())
        #expect(try Data(contentsOf: fixture.file) == before)
        #expect(try await height(in: fixture.file) == 0)
        #expect(try await height(in: saved) > 0.05)
        #expect(fixture.owner.components[Terrain3DSource.self]?.source == saved.path)
        #expect(original.source == fixture.file.path)
        #expect(fixture.owner.components[Terrain3DHeightEdit.self] == nil)
        #expect(fixture.owner.components[Terrain3DSave.self] == nil)
    }

    @Test("Cancelling before editing or during a filesystem write preserves original assets", arguments: [false, true])
    func cancelledVersion(duringSave: Bool) async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try Data(contentsOf: fixture.file)
        let original = fixture.owner.components[Terrain3DSource.self]
        let result = try await perform(fixture, operation: .raise, cancel: true, duringSave: duringSave)
        guard case let .failure(error) = result else {
            #expect(false, "Cancellation must not publish a resource version")
            return
        }
        #expect(error is CancellationError)
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(5))
        while clock.now < deadline {
            let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
            if !files.contains(where: { $0.hasPrefix("edit-") && $0.hasSuffix(".aterrain") }) { break }
            try await fixture.app.withExclusiveWorldAccess { await fixture.app.main.runScheduler(.preUpdate) }
            try await Task.sleep(for: .milliseconds(1))
        }
        let remaining = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path)
        #expect(!remaining.contains { $0.hasPrefix("edit-") && $0.hasSuffix(".aterrain") })
        #expect(fixture.owner.components[Terrain3DSource.self] == original)
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("A no-op gesture creates no resource version or history change")
    func unchangedVersion() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let files = try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted()
        let original = fixture.owner.components[Terrain3DSource.self]
        let result = try await perform(fixture, operation: .smooth)
        guard case let .success(saved) = result else {
            #expect(false, "Smoothing a flat surface should finish without a changed version")
            return
        }
        #expect(saved == nil)
        #expect(fixture.owner.components[Terrain3DSource.self] == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: fixture.root.path).sorted() == files)
    }

    @Test("Replacing the saved root after loading rejects a stroke captured from the earlier surface")
    func externalReplacement() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        var changed = Terrain3D(resolution: 65, size: 64)
        changed.heights = Array(repeating: 3, count: 65 * 65)
        let storage = try TerrainHeightStorage(importing: changed)
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(spacing: 1, originX: -32, originZ: -32), at: fixture.file.path)
        let external = try Data(contentsOf: fixture.file)
        let result = try await perform(fixture, operation: .raise)
        guard case let .failure(error) = result else {
            #expect(false, "A captured gesture must not silently adopt an external resource generation")
            return
        }
        if case .sourceChanged? = error as? EditorTerrainSourceAuthoring.Failure {} else {
            #expect(false, "The authoring transaction must identify the stale source baseline")
        }
        #expect(try Data(contentsOf: fixture.file) == external)
        #expect(try await height(in: fixture.file) == 3)
    }

    @Test("Own image materials, surface paint, imported GLB prototypes and instanced mesh strokes survive saved resource versions")
    func resourceTools() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let before = try Data(contentsOf: fixture.file)
        let imageFile = fixture.root.appendingPathComponent("custom.png")
        let image = Image(width: 2, height: 2, data: Data([UInt8](repeating: 255, count: 16)))
        try image.writePNG(to: imageFile)
        _ = try #require(try? (await perform(fixture, operation: .raise, command: .texture(imageFile, layerID: 0))).get())
        let material = try #require(fixture.owner.components[Terrain3DSourceSurface.self]?.manifest?.materials)
        #expect(material.layers.count == 1)
        #expect(material.layers[0].albedoPath != nil)
        #expect(material.layers[0].variation.isEnabled)
        var paint = TerrainSurfaceBrushSettings(operation: .paintLayer, radius: 3, strength: 1)
        paint.layerID = 0
        let points: [TerrainBrushPoint] = [.init(position: .zero, time: 0), .init(position: .zero, time: 0.25)]
        _ = try #require(try? (await perform(fixture, operation: .raise, command: .surface(.init(settings: paint, points: points)))).get())
        let paintedStorage = try #require(fixture.owner.components[Terrain3DSourceSurface.self]?.storage)
        #expect(paintedStorage.paint(atSample: .init(x: 32, z: 32))?.overrideStrength ?? 0 > 0)
        let modelFile = fixture.root.appendingPathComponent("rock.glb")
        try modelBytes().write(to: modelFile)
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        _ = try #require(try? (await perform(fixture, operation: .raise, command: .mesh(modelFile))).get())
        #expect(fixture.owner.components[Terrain3DSourceSurface.self]?.manifest?.meshPrototypes.count == 1)
        var mesh = TerrainInstanceBrushSettings(prototypeID: 0, radius: 4, density: 0.2)
        mesh.minimumDistance = 0.5
        let result = try #require(try? (await perform(fixture, operation: .raise, command: .instances(.init(settings: mesh, points: points)))).get())
        let cache = try await TerrainRegionCache.open(manifestAt: result.path)
        let region = try #require(try await cache.loadRegion(at: .init(x: 0, z: 0)))
        #expect(!region.instances.isEmpty)
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("Saved volume solids accept material fields and noise generation remains a separate undoable source version")
    func volumeAndNoise() async throws {
        let fixture = try await fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let operation = TerrainVolumeOperation(operation: .union, operand: .primitive(.box(halfExtents: [3, 1, 2])), transform: .init(translation: [0, 3, 0]))
        _ = try #require(try? (await perform(fixture, operation: .raise, command: .volume(operation))).get())
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 0, name: "Grass"), .init(id: 1, name: "Rock")],
            fallbackLayerID: 0,
            rules: [.init(layerID: 1, height: .init(minimum: 2, maximum: 20))]
        )
        let version = try #require(try? (await perform(fixture, operation: .raise, command: .materials(palette))).get())
        #expect(fixture.owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(fixture.owner.components[Terrain3DSourceSurface.self]?.manifest?.materials?.layers.count == 2)
        let oldRoot = try Data(contentsOf: version)
        let generated = try #require(try? (await perform(fixture, operation: .raise, command: .generate(.init(seed: 41, amplitude: 5, frequency: 0.04)))).get())
        #expect(try await height(in: generated) != 0)
        #expect(try Data(contentsOf: version) == oldRoot)
    }

    private func modelBytes() throws -> Data {
        let positions: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        let indices: [UInt16] = [0, 2, 1, 0, 1, 3, 0, 3, 2, 1, 2, 3]
        var binary = positions.withUnsafeBytes { Data($0) }
        binary.append(indices.withUnsafeBytes { Data($0) })
        let object: [String: Any] = [
            "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0]],
            "buffers": [["byteLength": binary.count]],
            "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 48], ["buffer": 0, "byteOffset": 48, "byteLength": 24]],
            "accessors": [
                ["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3", "min": [0, 0, 0], "max": [1, 1, 1]],
                ["bufferView": 1, "componentType": 5123, "count": 12, "type": "SCALAR"],
            ],
            "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1]]]],
        ]
        var json = try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
        while !json.count.isMultiple(of: 4) { json.append(32) }
        var result = Data()
        func append(_ value: UInt32) {
            var word = value.littleEndian
            withUnsafeBytes(of: &word) { result.append(contentsOf: $0) }
        }
        append(0x46546c67); append(2); append(UInt32(12 + 8 + json.count + 8 + binary.count))
        append(UInt32(json.count)); append(0x4e4f534a); result.append(json)
        append(UInt32(binary.count)); append(0x004e4942); result.append(binary)
        return result
    }

    private struct Fixture {
        let root: URL
        let file: URL
        let app: AppWorlds
        let owner: Entity
    }

    private func fixture() async throws -> Fixture {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("TerrainAuthoring-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("original.aterrain")
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(spacing: 1, originX: -32, originZ: -32), at: file.path)
        let app = AppWorlds(main: World(name: "Terrain authoring"))
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") {
            Transform()
            Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil, queries: .init())
        }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while clock.now < deadline {
            try await app.withExclusiveWorldAccess { await app.main.runScheduler(.preUpdate) }
            if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(owner.components[Terrain3DSourceSurface.self] != nil)
        return Fixture(root: root, file: file, app: app, owner: owner)
    }

    private final class Pending {
        var task: Task<Void, Never>?
        var result: Result<URL?, any Error>?
    }

    private func perform(
        _ fixture: Fixture,
        operation: TerrainHeightBrushOperation,
        cancel: Bool = false,
        duringSave: Bool = false,
        command: EditorTerrainStrokeCommand? = nil
    ) async throws -> Result<URL?, any Error> {
        let pending = Pending()
        let storage = try #require(fixture.owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        let settings = TerrainHeightBrushSettings(operation: operation, radius: 2, strength: 2)
        let brush = TerrainHeightBrushStroke(settings: settings, points: [.init(position: .zero, time: 0), .init(position: .zero, time: 0.2)])
        pending.task = Task { @MainActor in
            do {
                let saved = try await EditorTerrainSourceAuthoring.applyHeightStroke(
                    to: fixture.owner,
                    application: fixture.app,
                    expectedStorage: storage,
                    expectedRevision: revision,
                    brush: brush,
                    command: command,
                    assetsRoot: fixture.root,
                    onProgress: { phase in
                        if cancel {
                            switch phase {
                            case .preparing where !duringSave: pending.task?.cancel()
                            case .writing where duringSave: pending.task?.cancel()
                            default: break
                            }
                        }
                    }
                )
                pending.result = .success(saved)
            } catch {
                print("TERRAIN_AUTHORING_ERROR", String(reflecting: error))
                pending.result = .failure(error)
            }
        }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
        while pending.result == nil, clock.now < deadline {
            try await fixture.app.withExclusiveWorldAccess { await fixture.app.main.runScheduler(.preUpdate) }
            try await Task.sleep(for: .milliseconds(1))
        }
        if pending.result == nil { pending.task?.cancel() }
        return try #require(pending.result)
    }

    private func height(in file: URL) async throws -> Float {
        let cache = try await TerrainRegionCache.open(manifestAt: file.path)
        let manifest = await cache.manifest
        var regions: [TerrainRegionAsset] = []
        for reference in manifest.heightRegions {
            if let region = try await cache.loadRegion(at: .init(x: Int(reference.x), z: Int(reference.z))) { regions.append(region) }
        }
        let storage = try TerrainHeightStorage(regions: regions, spacing: manifest.spacing, origin: [manifest.originX, manifest.originZ])
        return try #require(storage.height(at: .zero))
    }
}
