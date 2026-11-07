@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Mesh Terrain short pointer gestures", .serialized)
struct EditorMeshTerrainFastBrushTests {
    @Test("A paint drag released between render frames covers its whole path")
    func meshPaintCapturesReleasePosition() async throws {
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
        let layer = try #require(palette.layers.first { $0.id != palette.fallbackLayerID })
        let a = try #require(viewport.project([-6, 0, 0], size: viewport.viewportSize))
        let b = try #require(viewport.project([6, 0, 0], size: viewport.viewportSize))
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0

        viewport.terrainEditing.dockTab = "Materials"
        viewport.terrainEditing.radius = 2.5
        viewport.terrainEditing.strength = 12
        viewport.terrainEditing.sourceLayerID = layer.id
        viewport.terrainEditing.sourceTool = .paint
        try #require(viewport.handleTerrainPointer(at: a, began: true))
        try #require(viewport.handleTerrainPointer(at: b, ended: true))
        try await support.finish(fixture)
        let asset = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset)
        let patch = try #require(asset.compiled?.patches.first)
        let paintedX = (patch.paint?.samples ?? []).map { patch.surface.positions[Int(patch.surface.indices[$0.corner])].x }
        #expect(paintedX.contains(-6))
        #expect(paintedX.contains(0))
        #expect(paintedX.contains(6))
        #expect(asset.document.paint.contains { $0.anchor.point.x > 5 })
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 1)
    }
}
