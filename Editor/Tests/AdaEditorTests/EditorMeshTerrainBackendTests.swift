@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Mesh terrain backend routing", .serialized)
struct EditorMeshTerrainBackendTests {
    @Test("Heightfield generation leaves all resources unchanged when Mesh Terrain is selected")
    func selectedMeshDoesNotGenerateAnotherTerrain() async throws {
        let support = EditorTerrainSourceViewportTests()
        let fixture = try await support.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.viewport.terrainEditing.creationBackend = .mesh
        fixture.viewport.terrainEditing.noise.amplitude = 0
        fixture.viewport.terrainEditing.sourceActions?.create()
        try await support.finish(fixture)
        let meshID = try #require(fixture.viewport.selectedEditorID)
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < loadDeadline {
            try await support.pump(fixture, frames: 1)
            if fixture.viewport.runtimeEntity(for: meshID)?.components[MeshTerrain3DSourceSurface.self] != nil,
                fixture.viewport.runtimeEntity(for: fixture.id)?.components[Terrain3DSourceSurface.self] != nil { break }
        }
        try #require(fixture.viewport.runtimeEntity(for: meshID)?.components[MeshTerrain3DSourceSurface.self] != nil)
        try #require(fixture.viewport.runtimeEntity(for: fixture.id)?.components[Terrain3DSourceSurface.self] != nil)
        fixture.viewport.selectedEditorID = fixture.id
        fixture.viewport.refreshTerrainSourceControls()
        let controlsDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        while fixture.viewport.terrainEditing.sourceManifest == nil, ContinuousClock.now < controlsDeadline {
            try await support.pump(fixture, frames: 1)
        }
        try #require(fixture.viewport.terrainEditing.sourceManifest != nil)
        fixture.viewport.selectedEditorID = meshID
        let content = fixture.viewport.sceneContent
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        fixture.viewport.terrainEditing.noise.amplitude = 8
        fixture.viewport.terrainEditing.sourceActions?.generate()
        try await support.finish(fixture)
        #expect(fixture.viewport.sceneContent == content)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == files)
        #expect(fixture.viewport.terrainEditing.sourceStatus == "Choose a Heightfield for this tool.")
    }
}
