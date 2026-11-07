@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
import AdaInput
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Mesh terrain viewport history", .serialized)
struct EditorMeshTerrainHistoryTests {
    @Test("Detaching restores the independent source and ground in one undoable edit")
    func detachJoinedMeshRestoresGroundAndSource() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await EditorMeshTerrainDragTests().joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport, workbench = fixture.workbench
        let owner = try #require(viewport.runtimeEntity(for: terrainID))
        let source = try #require(viewport.runtimeEntity(for: sourceID))
        let joined = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let binding = try #require(source.components[MeshTerrain3DBinding.self])
        let identity = try #require(source.components[MeshTerrain3DIdentity.self])
        let count = workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let ray = Ray(origin: [0, 5, 0], direction: [0, -1, 0])

        viewport.terrainEditing.sourceActions?.detach?()
        try await support.finish(fixture)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        #expect(source.components[MeshTerrain3DBinding.self] == nil)
        #expect(source.components[MeshTerrain3DSourceMask.self] == nil)
        #expect(source.components[MeshTerrain3DIdentity.self] == identity)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(ray)?.position.y == 0)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.document.modifiers.isEmpty == true)
        #expect(viewport.sceneModel?.entities.first(where: { $0.id == sourceID })?.components[String(reflecting: MeshTerrain3DBinding.self)] == nil)
        let detached = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        try #require(detached != joined)
        #expect(workbench.sceneUndoHistory["terrain"]?.count == count + 1)

        for redo in [false, true] {
            try #require(workbench.performDocumentHistory(redo: redo))
            let document = try #require(workbench.activeSceneDocument)
            viewport.configure(sceneContent: document.content, model: document.sceneModel, sourceURL: fixture.scene, resourceRootURL: fixture.root,
                isHistoryChange: true, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
            try await support.finish(fixture)
            #expect(viewport.runtimeEntity(for: terrainID) === owner)
            #expect(viewport.runtimeEntity(for: sourceID) === source)
            #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == (redo ? detached : joined))
            #expect(source.components[MeshTerrain3DBinding.self] == (redo ? nil : binding))
            #expect(source.components[MeshTerrain3DSourceMask.self]?.owner == (redo ? nil : owner.id))
            #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(ray)?.position.y == (redo ? 0 : 1))
        }
    }

    @Test("Rapid history commands retain only the latest requested generation", arguments: [false, true])
    func rapidHistoryKeepsLatestGeneration(finalUndo: Bool) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await EditorMeshTerrainDragTests().joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        let source = try #require(fixture.viewport.runtimeEntity(for: sourceID))
        fixture.viewport.setActiveTool(.translate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        let end = try #require(fixture.viewport.project(gizmo.origin + Vector3(gizmo.worldLength + 3, 0, 0), size: fixture.viewport.viewportSize))
        try #require(fixture.viewport.beginTransformDragIfNeeded(at: start, button: .left))
        try #require(fixture.viewport.updateTransformDrag(to: end))
        fixture.viewport.endTransformDrag()
        try await support.finish(fixture)
        try #require(fixture.viewport.terrainEditing.sourceFailure == nil)
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        for redo in finalUndo ? [false, true, false] : [false, true] {
            try #require(fixture.workbench.performDocumentHistory(redo: redo))
            let document = try #require(fixture.workbench.activeSceneDocument)
            let viewport = fixture.viewport, workbench = fixture.workbench
            viewport.configure(sceneContent: document.content, model: document.sceneModel, sourceURL: fixture.scene, resourceRootURL: fixture.root,
                isHistoryChange: true, onSelectionChanged: { _ in }, onDocumentContentChanged: { [weak viewport, weak workbench] content in
                    workbench?.updateSceneDocument(id: "terrain") { changed in
                        changed.content = content; changed.sceneModel = viewport?.sceneModel; changed.isDirty = true
                    }
                })
            #expect(viewport.runtimeEntity(for: terrainID) === owner)
            #expect(viewport.runtimeEntity(for: sourceID) === source)
            #expect(owner.components[MeshTerrain3DSourceSurface.self]?.queries != nil)
        }
        if !finalUndo {
            // Undo followed by Redo before an update returns to the resident version.
            // Draining that mailbox must not require a scene frame to publish a no-op.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while fixture.viewport.terrainEditing.isSourceBusy, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!fixture.viewport.terrainEditing.isSourceBusy)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var ready = false
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            let terrain = fixture.viewport.runtimeEntity(for: terrainID), root = fixture.viewport.runtimeEntity(for: sourceID)
            let queries = terrain?.components[MeshTerrain3DSourceSurface.self]?.queries
            #expect(queries != nil)
            if let queries, let x = root?.components[Transform.self]?.position.x {
                let y = try queries.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y
                #expect(abs(x) < 0.001 ? y == 1 : abs(x - 3) < 0.001 && y == 0)
                if !fixture.viewport.terrainEditing.isSourceBusy, abs(x - (finalUndo ? 0 : 3)) < 0.001 { ready = true; break }
            }
        }
        #expect(ready)
        #expect(fixture.viewport.terrainEditing.sourceFailure == nil)
        #expect(fixture.viewport.runtimeEntity(for: terrainID) === owner)
        #expect(fixture.viewport.runtimeEntity(for: sourceID) === source)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == files)
    }

    @Test("Undo and Redo retain the visible terrain until geometry and source pose can publish together")
    func sourceHistoryKeepsEveryFrameCoherent() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await EditorMeshTerrainDragTests().joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        let source = try #require(fixture.viewport.runtimeEntity(for: sourceID))
        let initial = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        fixture.viewport.setActiveTool(.translate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        let end = try #require(fixture.viewport.project(gizmo.origin + Vector3(gizmo.worldLength + 3, 0, 0), size: fixture.viewport.viewportSize))
        try #require(fixture.viewport.beginTransformDragIfNeeded(at: start, button: .left))
        try #require(fixture.viewport.updateTransformDrag(to: end))
        fixture.viewport.endTransformDrag()
        try await support.finish(fixture)
        try #require(fixture.viewport.terrainEditing.sourceFailure == nil)
        let moved = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        try #require(moved != initial)
        for redo in [false, true] {
            try #require(fixture.workbench.performDocumentHistory(redo: redo))
            let document = try #require(fixture.workbench.activeSceneDocument)
            let viewport = fixture.viewport, workbench = fixture.workbench
            viewport.configure(sceneContent: document.content, model: document.sceneModel, sourceURL: fixture.scene, resourceRootURL: fixture.root,
                isHistoryChange: true, onSelectionChanged: { _ in }, onDocumentContentChanged: { [weak viewport, weak workbench] content in
                    workbench?.updateSceneDocument(id: "terrain") { changed in
                        changed.content = content; changed.sceneModel = viewport?.sceneModel; changed.isDirty = true
                    }
                })
            // History must keep the resident world while the immutable version is prepared.
            #expect(viewport.runtimeEntity(for: terrainID) === owner)
            #expect(viewport.runtimeEntity(for: sourceID) === source)
            #expect(viewport.runtimeEntity(for: terrainID)?.components[MeshTerrain3DSourceSurface.self]?.queries != nil)
            let expected = redo ? moved : initial
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            var ready = false
            while ContinuousClock.now < deadline {
                try await support.pump(fixture, frames: 1)
                let terrain = viewport.runtimeEntity(for: terrainID), root = viewport.runtimeEntity(for: sourceID)
                let surface = terrain?.components[MeshTerrain3DSourceSurface.self]
                #expect(surface?.queries != nil)
                if let queries = surface?.queries, let x = root?.components[Transform.self]?.position.x {
                    let y = try queries.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y
                    if abs(x) < 0.001 { #expect(y == 1) }
                    else if abs(x - 3) < 0.001 { #expect(y == 0) }
                    else { Issue.record("History published an unexpected source pose") }
                }
                if surface?.asset.compiled?.inputKey == expected, !viewport.terrainEditing.isSourceBusy,
                    abs((root?.components[Transform.self]?.position.x ?? -100) - (redo ? 3 : 0)) < 0.001 { ready = true; break }
            }
            #expect(ready)
            #expect(viewport.terrainEditing.sourceFailure == nil)
            #expect(viewport.runtimeEntity(for: terrainID) === owner)
            #expect(viewport.runtimeEntity(for: sourceID) === source)
        }
    }
}
