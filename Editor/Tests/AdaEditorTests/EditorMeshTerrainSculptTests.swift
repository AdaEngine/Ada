@_spi(AdaEngine) @testable import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Mesh terrain sculpting", .serialized)
struct EditorMeshTerrainSculptTests {
    @Test("Smooth and Flatten edit the selected mesh surface and save one new generation", arguments: [false, true])
    func meshSurfaceSmoothAndFlatten(flatten: Bool) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, meshID, owner) = try await meshFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        let center: Vector3 = [4, 0, 0]
        let ray = Ray(origin: center + [0, 5, 0], direction: [0, -1, 0])
        func height() throws -> Float {
            try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(ray)?.position.y)
        }
        func stamp(at center: Vector3) throws {
            let point = try #require(viewport.project(center, size: viewport.viewportSize))
            try #require(viewport.handleTerrainPointer(at: point, began: true))
            try #require(viewport.handleTerrainPointer(at: point, ended: true))
        }
        viewport.terrainEditing.dockTab = "Sculpt"
        viewport.terrainEditing.mode = .raise
        viewport.terrainEditing.radius = 1.9
        viewport.terrainEditing.strength = 12
        try stamp(at: center)
        try await support.finish(fixture)
        let before = try height()
        try #require(before > 0.05)
        let previous = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0

        viewport.terrainEditing.mode = flatten ? .flatten : .smooth
        viewport.terrainEditing.radius = 8
        viewport.terrainEditing.strength = 20
        try stamp(at: flatten ? .zero : center + [0, before, 0])
        try await support.finish(fixture)
        #expect(try height() < before - 0.008)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        #expect(viewport.runtimeEntity(for: meshID) === owner)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey != previous)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history + 1)
    }

    @Test("Raise previews the selected triangle surface and saves one mesh terrain version")
    func raiseMeshTerrainPublishesBeforeRelease() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, meshID, owner) = try await meshFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        let original = try #require(viewport.sceneModel)
        let oldMesh = try #require(original.entities.first { $0.id == meshID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let oldLegacy = try #require(original.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource])
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let ray = Ray(origin: [0, 5, 0], direction: [0, -1, 0])
        func height() throws -> Float {
            try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(ray)?.position.y)
        }
        try #require(try height() == 0)
        viewport.terrainEditing.dockTab = "Sculpt"
        viewport.terrainEditing.mode = .raise
        viewport.terrainEditing.radius = 6
        viewport.terrainEditing.strength = 6
        let point = try #require(viewport.project(.zero, size: viewport.viewportSize))
        #expect(viewport.handleTerrainPointer(at: point, began: true))
        let previewDeadline = ContinuousClock.now.advanced(by: .seconds(6))
        var preview: Float = 0
        while ContinuousClock.now < previewDeadline {
            _ = viewport.updateTerrainStroke(deltaTime: 1 / 60)
            try await support.pump(fixture, frames: 1)
            preview = try height()
            if preview > 0.005 { break }
        }
        #expect(preview > 0.005)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count)
        #expect(viewport.handleTerrainPointer(at: point, ended: true))
        try await support.finish(fixture)
        #expect(try height() > 0.005)
        #expect(viewport.runtimeEntity(for: meshID) === owner)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count + 1)
        let updated = try #require(fixture.workbench.activeSceneDocument?.sceneModel)
        #expect(updated.entities.first { $0.id == fixture.id }?.components[EditorBuiltInComponentType.terrain3DSource] == oldLegacy)
        let saved = try #require(updated.entities.first { $0.id == meshID }?.components[EditorBuiltInComponentType.terrain3DSource])
        #expect(saved != oldMesh)
    }

    @Test("Lower previews a depression and cancel restores the original mesh without files or history", arguments: [false, true])
    func lowerMeshTerrainCancelsWithoutHistory(afterPreview: Bool) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, _, owner) = try await meshFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        let originalKey = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let content = viewport.sceneContent
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        viewport.terrainEditing.dockTab = "Sculpt"
        viewport.terrainEditing.mode = .lower
        viewport.terrainEditing.radius = 6
        viewport.terrainEditing.strength = 6
        let point = try #require(viewport.project(.zero, size: viewport.viewportSize))
        try #require(viewport.handleTerrainPointer(at: point, began: true))
        let ray = Ray(origin: [0, 5, 0], direction: [0, -1, 0])
        func height() throws -> Float {
            try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(ray)?.position.y)
        }
        if afterPreview {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while ContinuousClock.now < deadline {
                _ = viewport.updateTerrainStroke(deltaTime: 1 / 60)
                try await support.pump(fixture, frames: 1)
                if try height() < -0.005 { break }
            }
            #expect(try height() < -0.005)
        }
        #expect(viewport.handleTerrainPointer(at: point, cancelled: true))
        if !afterPreview {
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while viewport.terrainEditing.isSourceBusy, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            #expect(!viewport.terrainEditing.isSourceBusy)
        }
        try await support.finish(fixture)
        #expect(try height() == 0)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == originalKey)
        #expect(owner.components[MeshTerrain3DEdit.self] == nil)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        #expect(viewport.sceneContent == content)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == files)
    }

    private func meshFixture(_ support: EditorTerrainSourceViewportTests) async throws -> (EditorTerrainSourceViewportTests.Fixture, String, Entity) {
        let fixture = try await support.fixture()
        let viewport = fixture.viewport
        viewport.terrainEditing.creationBackend = .mesh
        viewport.terrainEditing.noise.amplitude = 0
        viewport.terrainEditing.sourceActions?.create()
        try await support.finish(fixture)
        let meshID = try #require(viewport.selectedEditorID)
        let loadDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < loadDeadline {
            try await support.pump(fixture, frames: 1)
            if viewport.runtimeEntity(for: meshID)?.components[MeshTerrain3DSourceSurface.self] != nil,
                viewport.runtimeEntity(for: fixture.id)?.components[Terrain3DSourceSurface.self] != nil { break }
        }
        let owner = try #require(viewport.runtimeEntity(for: meshID))
        try #require(owner.components[MeshTerrain3DSourceSurface.self]?.queries != nil)
        return (fixture, meshID, owner)
    }
}
