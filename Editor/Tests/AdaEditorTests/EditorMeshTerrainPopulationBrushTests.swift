@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Mesh Terrain population brush", .serialized)
struct EditorMeshTerrainPopulationBrushTests {
    @Test("Mesh Instancing paints generated objects on the selected triangle surface and erases their coverage")
    func paintAndEraseMeshTerrainPopulation() async throws {
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
        let modelFile = fixture.root.appendingPathComponent("Grass.vox")
        let voxel = VOXModel(sizeX: 1, sizeY: 1, sizeZ: 1, voxels: [.init(x: 0, y: 0, z: 0, colorIndex: 1)])
        try VOXWriter().encode(model: voxel, palette: .fallback).write(to: modelFile)
        viewport.performTerrainResourceCommand(.mesh(modelFile))
        try await support.finish(fixture)
        let prototype = try #require(owner.components[MeshTerrain3DSourceResources.self]?.manifest.meshPrototypes.first)
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let coordinate = TerrainTileCoordinate(x: 0, z: 0)
        let original = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.tileGeneration(at: coordinate))
        let point = try #require(viewport.project([4, 0, 0], size: viewport.viewportSize))
        viewport.terrainEditing.dockTab = "Mesh Instancing"
        viewport.terrainEditing.radius = 6
        viewport.terrainEditing.meshDensity = 1
        viewport.terrainEditing.sourcePrototypeID = prototype.id
        viewport.terrainEditing.sourceTool = .scatter
        try #require(viewport.handleTerrainPointer(at: point, began: true))
        try #require(viewport.handleTerrainPointer(at: point, ended: true))
        try await support.finish(fixture)
        let painted = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        let placements = try #require(painted.asset.compiled?.placements)
        #expect(!placements.isEmpty)
        #expect(placements.allSatisfy { $0.ownership == .generated && $0.prototypeID == prototype.id })
        #expect(painted.asset.populationRules.count == 1)
        #expect(painted.queries?.tileGeneration(at: coordinate) == original)
        let visible = owner.children.compactMap { $0.components[Mesh3DInstancesComponent.self] }.flatMap(\.instances).map(\.id)
        #expect(Set(visible) == Set(placements.map(\.id)))
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 1)

        viewport.terrainEditing.sourceTool = .eraseMeshes
        try #require(viewport.handleTerrainPointer(at: point, began: true))
        try #require(viewport.handleTerrainPointer(at: point, ended: true))
        try await support.finish(fixture)
        let erased = try #require(owner.components[MeshTerrain3DSourceSurface.self])
        #expect(erased.asset.compiled?.placements.isEmpty == true)
        #expect(erased.asset.populationRules.first?.id == painted.asset.populationRules.first?.id)
        #expect(owner.children.allSatisfy { $0.components[Mesh3DInstancesComponent.self] == nil })
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 2)
        #expect(viewport.terrainEditing.sourceFailure == nil)
    }
}
