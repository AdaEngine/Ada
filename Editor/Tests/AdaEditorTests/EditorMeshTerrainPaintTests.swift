@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Mesh Terrain material gestures", .serialized)
struct EditorMeshTerrainPaintTests {
    @Test("The Materials brush and eraser each save one version without replacing geometry")
    func paintAndEraseMeshTerrain() async throws {
        let support = EditorTerrainSourceViewportTests()
        let fixture = try await support.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        viewport.terrainEditing.creationBackend = .mesh
        viewport.terrainEditing.noise.amplitude = 0
        viewport.terrainEditing.sourceActions?.create()
        try await support.finish(fixture)
        let meshID = try #require(viewport.selectedEditorID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            if viewport.runtimeEntity(for: meshID)?.components[MeshTerrain3DSourceSurface.self] != nil { break }
        }
        let owner = try #require(viewport.runtimeEntity(for: meshID))
        viewport.terrainEditing.sourceActions?.materials()
        try await support.finish(fixture)
        let palette = try #require(owner.components[MeshTerrain3DSourceResources.self]?.manifest.materials)
        let paint = try #require(palette.layers.first { $0.id != palette.fallbackLayerID })
        let original = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let point = try #require(viewport.project([4, 0, 0], size: viewport.viewportSize))
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let queryGeneration = try #require(original.queries?.tileGeneration(at: coordinate))

        viewport.terrainEditing.dockTab = "Materials"
        viewport.terrainEditing.radius = 5
        viewport.terrainEditing.strength = 60
        viewport.terrainEditing.sourceLayerID = paint.id
        viewport.terrainEditing.sourceTool = .paint
        try #require(viewport.handleTerrainPointer(at: point, began: true))
        try #require(viewport.handleTerrainPointer(at: point, ended: true))
        try await support.finish(fixture)
        let painted = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        #expect(painted.asset.document.paint.first?.operation == .paint(layer: paint.id))
        #expect(painted.asset.compiled?.patches.first?.paint?.samples.isEmpty == false)
        #expect(painted.queries?.tileGeneration(at: coordinate) == queryGeneration)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 1)
        let model = try #require(viewport.sceneModel)
        let payload = try #require(model.entities.first { $0.id == meshID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let path = try EditorTerrainSourcePayload.decode(payload).source
        let file = try EditorTerrainResource.resolve(path, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let manifest = try TerrainManifestAsset(data: Data(contentsOf: file))
        let meshFile = file.deletingLastPathComponent().appendingPathComponent(try #require(manifest.meshDocumentFileName))
        let saved = try MeshTerrainDocumentAsset(data: Data(contentsOf: meshFile))
        #expect(saved.document.paint == painted.asset.document.paint)

        viewport.terrainEditing.sourceTool = .erasePaint
        try #require(viewport.handleTerrainPointer(at: point, began: true))
        try #require(viewport.handleTerrainPointer(at: point, ended: true))
        try await support.finish(fixture)
        let erased = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        #expect(erased.asset.document.paint.last?.operation == .erase)
        #expect(erased.asset.compiled?.patches.first?.paint == nil)
        #expect(erased.queries?.tileGeneration(at: coordinate) == queryGeneration)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 2)
        #expect(viewport.runtimeEntity(for: meshID) === owner)
    }
}
