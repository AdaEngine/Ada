@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Mesh Terrain project imports", .serialized)
struct EditorMeshTerrainImportTests {
    @Test("Mesh Terrain imports and validates the selected texture and mesh without replacing compiled geometry")
    func importsMeshTerrainPaletteResources() async throws {
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
        let original = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let previous = try #require(owner.components[MeshTerrain3DSourceResources.self]?.manifest.meshDocumentFileName)
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0

        let albedo = fixture.root.appendingPathComponent("Bark.png")
        let png = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAEUlEQVR4nGPoCFX6D8IMMAYARWYH+TH0L8MAAAAASUVORK5CYII="))
        try png.write(to: albedo)
        viewport.performTerrainResourceCommand(.texture(albedo, layerID: 5))
        try await support.finish(fixture)
        let painted = try #require(owner.components[MeshTerrain3DSourceResources.self]?.manifest)
        #expect(painted.materials?.layers.first?.id == 5)
        #expect(painted.meshDocumentFileName == previous)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == original)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 1)

        let prototype = fixture.root.appendingPathComponent("Grass.vox")
        let model = VOXModel(sizeX: 1, sizeY: 1, sizeZ: 1, voxels: [.init(x: 0, y: 0, z: 0, colorIndex: 1)])
        try VOXWriter().encode(model: model, palette: .fallback).write(to: prototype)
        viewport.performTerrainResourceCommand(.mesh(prototype))
        try await support.finish(fixture)
        let placed = try #require(owner.components[MeshTerrain3DSourceResources.self]?.manifest)
        #expect(placed.meshPrototypes.count == 1)
        #expect(placed.materials == painted.materials)
        #expect(placed.meshDocumentFileName == previous)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 2)

        let invalid = fixture.root.appendingPathComponent("Invalid.vox")
        try Data("not a VOX".utf8).write(to: invalid)
        let accepted = owner.components[Terrain3DSource.self]?.source
        let paths = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        viewport.performTerrainResourceCommand(.mesh(invalid))
        try await support.finish(fixture)
        #expect(viewport.terrainEditing.sourceFailure != nil)
        #expect(owner.components[Terrain3DSource.self]?.source == accepted)
        let afterFailure = try #require(owner.components[MeshTerrain3DSourceResources.self]?.manifest)
        #expect(try afterFailure.encodedData() == placed.encodedData())
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 2)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == paths)
    }
}
