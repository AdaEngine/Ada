@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Mesh Terrain palette authoring", .serialized)
struct EditorMeshTerrainPaletteTests {
    @Test("Automatic materials update the selected Mesh Terrain without changing its Heightfield neighbor")
    func paletteActionEditsSelectedMesh() async throws {
        let support = EditorTerrainSourceViewportTests()
        let fixture = try await support.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        viewport.terrainEditing.creationBackend = .mesh
        viewport.terrainEditing.noise.amplitude = 0
        viewport.terrainEditing.sourceActions?.create()
        try await support.finish(fixture)
        let terrainID = try #require(viewport.selectedEditorID)
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            if viewport.runtimeEntity(for: terrainID)?.components[MeshTerrain3DSourceSurface.self] != nil { break }
        }
        let owner = try #require(viewport.runtimeEntity(for: terrainID))
        let resident = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        let model = try #require(viewport.sceneModel)
        let legacy = model.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource]
        let source = try #require(model.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let uri = try EditorTerrainSourcePayload.decode(source).source
        let original = try EditorTerrainResource.resolve(uri, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let bytes = try Data(contentsOf: original)
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        viewport.terrainEditing.sourceActions?.materials()
        try await support.finish(fixture)
        let next = try #require(viewport.sceneModel)
        let nextPayload = try #require(next.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let nextURI = try EditorTerrainSourcePayload.decode(nextPayload).source
        let file = try EditorTerrainResource.resolve(nextURI, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let manifest = try TerrainManifestAsset(data: Data(contentsOf: file))
        #expect(manifest.materials?.layers.count == 3)
        #expect(nextURI != uri)
        #expect(next.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource] == legacy)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 1)
        #expect(viewport.runtimeEntity(for: terrainID) === owner)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == resident.asset.compiled?.inputKey)
        #expect(try Data(contentsOf: original) == bytes)
    }
}
