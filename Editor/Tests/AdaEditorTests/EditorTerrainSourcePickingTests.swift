@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Editor terrain surface picking", .serialized)
struct EditorTerrainSourcePickingTests {
    @Test("Generated terrain selects its authored owner and orders hits in world distance", arguments: [false, true])
    func sourcePicking(reflected: Bool) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("TerrainPick-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 3, size: 2))
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        let file = root.appendingPathComponent("world.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(regions, manifest: .init(spacing: 1, originX: -1, originZ: -1), at: file.path)
        let app = AppWorlds(main: World(name: "Terrain picking"))
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(RenderWorldPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        let owner = app.main.spawn("Terrain") {
            Transform(scale: [3, reflected ? -2 : 2, 0.5], position: [10, 5, 0])
            Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil, queries: .init())
        }
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(10))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(owner.components[Terrain3DSourceSurface.self]?.queries != nil)
        let ray = Ray(origin: [12.1, 20, 0.35], direction: [0, -1, 0])
        #expect(EditorMeshPicking.pick(ray: ray, world: app.main, authoredEntities: ["terrain": owner.id], editorIDs: [owner.id: "terrain"], cameraID: nil) == "terrain",
            "A hit away from the transform origin must select the authored terrain through its committed surface")
        let engine = try #require(unsafe RenderEngine.shared)
        let cube = app.main.spawn("Closer cube") {
            Transform(position: [12.1, 10, 0.35])
            Mesh3DComponent(mesh: Mesh.generateCube(renderDevice: engine.renderDevice), materials: [PBRMaterial()])
        }
        let selected = EditorMeshPicking.pick(
            ray: ray,
            world: app.main,
            authoredEntities: ["terrain": owner.id, "cube": cube.id],
            editorIDs: [owner.id: "terrain", cube.id: "cube"],
            cameraID: nil
        )
        #expect(selected == "cube", "Local normalized terrain distance must not override a closer world-space object")
        let missed = EditorMeshPicking.pick(
            ray: Ray(origin: [30, 20, 0], direction: [0, -1, 0]),
            world: app.main,
            authoredEntities: ["terrain": owner.id],
            editorIDs: [owner.id: "terrain"],
            cameraID: nil
        )
        #expect(missed == nil)
    }
}
