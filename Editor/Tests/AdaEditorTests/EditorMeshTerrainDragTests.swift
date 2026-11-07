@_spi(Internal) @testable import AdaApp
@_spi(AdaEngine) @testable import AdaEngine
import AdaInput
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Mesh terrain source gestures", .serialized)
struct EditorMeshTerrainDragTests {
    @Test("Moving a joined object's parent saves both poses or rejects the whole move", arguments: [Float(3), Float(200)])
    func movingParentOfJoinedSource(x: Float) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support, grouped: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        let groupID = try #require(viewport.sceneModel?.entities.first { $0.id == sourceID }?.parent)
        let group = try #require(viewport.runtimeEntity(for: groupID))
        let source = try #require(viewport.runtimeEntity(for: sourceID))
        let terrain = try #require(viewport.runtimeEntity(for: terrainID))
        let originalFile = terrain.components[Terrain3DSource.self]?.source
        let originalScene = viewport.sceneContent
        let originalCount = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        var pose = try #require(group.components[Transform.self])
        pose.position.x = x

        viewport.beginSpatialTransform(editorID: groupID)
        viewport.updateSpatialTransform(pose, editorID: groupID)
        #expect(group.components[Transform.self]?.position.x == 0)
        #expect(viewport.sceneContent == originalScene)
        viewport.endSpatialTransform()
        try await support.finish(fixture)
        try await support.pump(fixture, frames: 2)

        let queries = try #require(terrain.components[MeshTerrain3DSourceSurface.self]?.queries)
        #expect(source.components[Transform.self]?.position.x == 0)
        #expect(source.components[MeshTerrain3DSourceMask.self]?.owner == terrain.id)
        if x == 3 {
            #expect(group.components[Transform.self]?.position.x == x)
            #expect(terrain.components[Terrain3DSource.self]?.source != originalFile)
            #expect(try queries.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
            #expect(try queries.raycast(.init(origin: [x, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
            #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == originalCount + 1)
        } else {
            #expect(viewport.terrainEditing.sourceFailure != nil)
            #expect(group.components[Transform.self]?.position.x == 0)
            #expect(terrain.components[Terrain3DSource.self]?.source == originalFile)
            #expect(try queries.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
            #expect(viewport.sceneContent == originalScene)
            #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == originalCount)
        }
    }

    @Test("Group Inspector movement and history keep two joined meshes in the same terrain generation")
    func groupInspectorAndHistoryRestoreTwoJoins() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, firstID) = try await joinedFixture(support, grouped: true)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        var model = try #require(viewport.sceneModel)
        let groupID = try #require(model.entities.first { $0.id == firstID }?.parent)
        let second = model.addEntity(template: .model3D, parentID: groupID)
        let index = try #require(model.entities.firstIndex { $0.id == second.id })
        model.entities[index].components[EditorBuiltInComponentType.mesh3D]?["size"] = .double(2)
        model.entities[index].components[EditorBuiltInComponentType.transform]?["position"] = .array([.double(-4), .double(0), .double(0)])
        viewport.sceneModel = model
        viewport.publishTerrainDocument()
        _ = viewport.reloadSceneRuntimeIfReady()
        viewport.selectedEditorID = second.id
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            if viewport.runtimeEntity(for: firstID)?.components[MeshTerrain3DBindingStatus.self]?.phase == .applied { break }
        }
        viewport.terrainEditing.sourceActions?.join?()
        try await support.finish(fixture)
        let settledDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < settledDeadline {
            try await support.pump(fixture, frames: 1)
            if viewport.runtimeEntity(for: firstID)?.components[MeshTerrain3DBindingStatus.self]?.phase == .applied { break }
        }

        let group = try #require(viewport.runtimeEntity(for: groupID))
        let first = try #require(viewport.runtimeEntity(for: firstID))
        let secondRoot = try #require(viewport.runtimeEntity(for: second.id))
        let terrain = try #require(viewport.runtimeEntity(for: terrainID))
        try #require(secondRoot.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
        let originalKey = try #require(terrain.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let historyCount = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let field = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform)?.fields.first { $0.key == "position" })
        viewport.selectedEditorID = groupID
        try #require(viewport.applyMeshTerrainInspectorField(field, value: "8, 0, 0"))
        try await support.finish(fixture)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        let movedKey = try #require(terrain.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        try #require(movedKey != originalKey)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == historyCount + 1)

        for redo in [false, true] {
            try #require(fixture.workbench.performDocumentHistory(redo: redo))
            let document = try #require(fixture.workbench.activeSceneDocument)
            viewport.configure(sceneContent: document.content, model: document.sceneModel, sourceURL: fixture.scene, resourceRootURL: fixture.root,
                isHistoryChange: true, onSelectionChanged: { _ in }, onDocumentContentChanged: { _ in })
            try await support.finish(fixture)
            #expect(viewport.runtimeEntity(for: groupID) === group)
            #expect(viewport.runtimeEntity(for: firstID) === first)
            #expect(viewport.runtimeEntity(for: second.id) === secondRoot)
            #expect(viewport.runtimeEntity(for: terrainID) === terrain)
            #expect(group.components[Transform.self]?.position.x == (redo ? 8 : 0))
            #expect(terrain.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == (redo ? movedKey : originalKey))
            let queries = try #require(terrain.components[MeshTerrain3DSourceSurface.self]?.queries)
            for x in [Float(0), -4, 8, 4] {
                #expect(try queries.raycast(.init(origin: [x, 5, 0], direction: [0, -1, 0]))?.position.y == ((x > 0) == redo ? 1 : 0))
            }
        }
    }

    @Test("Entering a joined object's position saves both surfaces or retains the accepted edit", arguments: [Float(3), Float(200)])
    func inspectorPositionKeepsJoinedSurface(x: Float) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        let source = try #require(viewport.runtimeEntity(for: sourceID))
        let terrain = try #require(viewport.runtimeEntity(for: terrainID))
        let field = try #require(EditorComponentRegistry.descriptor(named: EditorBuiltInComponentType.transform)?
            .fields.first { $0.key == "position" })
        let originalFile = terrain.components[Terrain3DSource.self]?.source
        let originalScene = viewport.sceneContent
        let originalCount = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0

        #expect(viewport.applyMeshTerrainInspectorField(field, value: "\(x), 0, 0"))
        #expect(viewport.sceneContent == originalScene)
        #expect(source.components[Transform.self]?.position.x == 0)
        try await support.finish(fixture)

        let queries = try #require(terrain.components[MeshTerrain3DSourceSurface.self]?.queries)
        if x == 3 {
            #expect(viewport.terrainEditing.sourceFailure == nil)
            #expect(source.components[Transform.self]?.position.x == x)
            #expect(terrain.components[Terrain3DSource.self]?.source != originalFile)
            #expect(try queries.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
            #expect(try queries.raycast(.init(origin: [x, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
            #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == originalCount + 1)
        } else {
            #expect(viewport.terrainEditing.sourceFailure != nil)
            #expect(source.components[Transform.self]?.position.x == 0)
            #expect(terrain.components[Terrain3DSource.self]?.source == originalFile)
            #expect(try queries.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
            #expect(viewport.sceneContent == originalScene)
            #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == originalCount)
        }
    }

    @Test("A spatial transform saves the joined object and its ground as one edit")
    func spatialTransformCommitsJoinedSurface() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let viewport = fixture.viewport
        let owner = try #require(viewport.runtimeEntity(for: terrainID))
        let source = try #require(viewport.runtimeEntity(for: sourceID))
        let oldFile = owner.components[Terrain3DSource.self]?.source
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        var pose = try #require(source.components[Transform.self])
        pose.position.x = 3

        viewport.beginSpatialTransform(editorID: sourceID)
        viewport.updateSpatialTransform(pose, editorID: sourceID)
        #expect(source.components[Transform.self]?.position.x == 0)
        viewport.endSpatialTransform()
        try await support.finish(fixture)
        #expect(viewport.terrainEditing.sourceFailure == nil)
        #expect(source.components[Transform.self]?.position.x == 3)
        #expect(owner.components[Terrain3DSource.self]?.source != oldFile)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count + 1)
    }

    @Test("Dragging a joined object past the terrain edge leaves the saved pose, geometry and draw mask intact")
    func rejectedJoinedDragRetainsOriginalSurface() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let root = try #require(fixture.viewport.runtimeEntity(for: sourceID))
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        let accepted = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let scene = fixture.viewport.sceneContent
        let history = fixture.workbench.sceneUndoHistory["terrain"]?.count
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        fixture.viewport.setActiveTool(.translate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        // Either direction can be outside the 128-unit terrain. Prefer the
        // projection that lies in front of the viewport camera.
        let end = try #require([Float(70), -70].lazy.compactMap { offset in
            fixture.viewport.project(gizmo.origin + Vector3(gizmo.worldLength + offset, 0, 0), size: fixture.viewport.viewportSize)
        }.first)
        try #require(fixture.viewport.beginTransformDragIfNeeded(at: start, button: .left))
        try #require(fixture.viewport.updateTransformDrag(to: end))
        fixture.viewport.endTransformDrag(cancelled: false)
        try await support.finish(fixture)
        #expect(fixture.viewport.terrainEditing.sourceFailure == "Move the whole joined mesh inside the terrain boundary.")
        #expect(fixture.viewport.sceneContent == scene)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == history)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == files)
        #expect(root.components[Transform.self]?.position == .zero)
        #expect(root.components[MeshTerrain3DProposedPose.self] == nil)
        #expect(root.components[MeshTerrain3DSourceMask.self]?.owner == owner.id)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == accepted)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
    }

    @Test("Joining uses the activated options and rejects an explicitly missing target", arguments: [false, true])
    func joiningCapturesOptionsAndRejectsMissingTarget(missing: Bool) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, _) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        let oldPayload = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let oldURI = try EditorTerrainSourcePayload.decode(oldPayload).source
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        fixture.viewport.terrainEditing.meshTargetEditorID = missing ? "disappeared" : terrainID
        fixture.viewport.terrainEditing.meshOperation = missing ? "Join" : "Subtract"
        fixture.viewport.terrainEditing.sourceActions?.join?()
        if !missing {
            // An observation refresh can arrive before the world-safe-point capture.
            fixture.viewport.terrainEditing.meshOperation = "Join"
            fixture.viewport.terrainEditing.meshTargetEditorID = "disappeared"
        }
        try await support.finish(fixture)
        let payload = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let uri = try EditorTerrainSourcePayload.decode(payload).source
        if missing {
            #expect(fixture.viewport.terrainEditing.sourceFailure == "The selected Mesh Terrain is unavailable. Choose another terrain.")
            #expect(uri == oldURI)
            #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count)
            #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == files)
        } else {
            #expect(fixture.viewport.terrainEditing.sourceFailure == nil)
            #expect(uri != oldURI)
            let file = try EditorTerrainResource.resolve(uri, sourceURL: fixture.scene, resourceRootURL: fixture.root)
            let manifest = try TerrainManifestAsset(data: Data(contentsOf: file))
            let name = try #require(manifest.meshDocumentFileName)
            let saved = try MeshTerrainDocumentAsset(data: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(name)))
            #expect(saved.document.modifiers.first?.operation == .subtract)
            #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == -1)
        }
    }

    @Test("Picking selects mesh ground and keeps coincident joined sources selectable")
    func meshTerrainPickingRetainsSourceSelection() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try await fixture.app.withWorldAccess {
            let editorIDs = Dictionary(uniqueKeysWithValues: fixture.viewport.entitiesByEditorID.map { ($0.value, $0.key) })
            let ground = EditorMeshPicking.pick(ray: .init(origin: [40, 5, 40], direction: [0, -1, 0]), world: fixture.app.main,
                authoredEntities: fixture.viewport.entitiesByEditorID, editorIDs: editorIDs, cameraID: nil)
            #expect(ground == terrainID)
            let joined = EditorMeshPicking.pick(ray: .init(origin: [0, 5, 0], direction: [0, -1, 0]), world: fixture.app.main,
                authoredEntities: fixture.viewport.entitiesByEditorID, editorIDs: editorIDs, cameraID: nil)
            #expect(joined == sourceID)
            #expect(fixture.viewport.runtimeEntity(for: sourceID)?.components[MeshTerrain3DSourceMask.self] != nil)
        }
    }

    @Test("A failed gesture restore keeps its last coherent pose and reports the failure")
    func cancelJoinedSourceDragReportsRestoreFailure() async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let root = try #require(fixture.viewport.runtimeEntity(for: sourceID))
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        let originalFile = try #require(owner.components[Terrain3DSource.self]?.source)
        let data = try Data(contentsOf: URL(fileURLWithPath: originalFile))
        defer { try? data.write(to: URL(fileURLWithPath: originalFile)) }
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        fixture.viewport.setActiveTool(.translate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        let end = try #require(fixture.viewport.project(gizmo.origin + Vector3(gizmo.worldLength + 3, 0, 0), size: fixture.viewport.viewportSize))
        try #require(fixture.viewport.beginTransformDragIfNeeded(at: start, button: .left))
        try #require(fixture.viewport.updateTransformDrag(to: end))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            if abs((root.components[Transform.self]?.position.x ?? 0) - 3) < 0.001,
                root.components[MeshTerrain3DProposedPose.self] == nil { break }
        }
        try #require(abs((root.components[Transform.self]?.position.x ?? 0) - 3) < 0.001)
        let acceptedPayload = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == sourceID }?.components[EditorBuiltInComponentType.transform])
        // Exercise a real worker failure: a terrain resource can disappear during a gesture.
        try FileManager.default.removeItem(atPath: originalFile)
        fixture.viewport.endTransformDrag(cancelled: true)
        try await support.finish(fixture)
        #expect(fixture.viewport.terrainEditing.sourceFailure != nil)
        #expect(fixture.viewport.sceneModel?.entities.first { $0.id == sourceID }?.components[EditorBuiltInComponentType.transform] == acceptedPayload)
        #expect(abs((root.components[Transform.self]?.position.x ?? 0) - 3) < 0.001)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [3, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count)
    }

    @Test("Cancelling a joined-source drag restores its accepted generation without saving", arguments: [false, true])
    func cancelJoinedSourceDrag(afterPreview: Bool) async throws {
        let support = EditorTerrainSourceViewportTests()
        let (fixture, terrainID, sourceID) = try await joinedFixture(support)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let root = try #require(fixture.viewport.runtimeEntity(for: sourceID))
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        let original = try #require(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey)
        let content = fixture.viewport.sceneContent
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        let files = try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted()
        fixture.viewport.setActiveTool(.translate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        let end = try #require(fixture.viewport.project(gizmo.origin + Vector3(gizmo.worldLength + 3, 0, 0), size: fixture.viewport.viewportSize))
        try #require(fixture.viewport.beginTransformDragIfNeeded(at: start, button: .left))
        try #require(fixture.viewport.updateTransformDrag(to: end))
        if afterPreview {
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while ContinuousClock.now < deadline {
                try await support.pump(fixture, frames: 1)
                if abs((root.components[Transform.self]?.position.x ?? 0) - 3) < 0.001,
                    root.components[MeshTerrain3DProposedPose.self] == nil { break }
            }
            try #require(abs((root.components[Transform.self]?.position.x ?? 0) - 3) < 0.001)
        }
        fixture.viewport.endTransformDrag(cancelled: true)
        if afterPreview {
            try await support.finish(fixture)
        } else {
            // No world update is needed when no provisional generation was ever accepted.
            // This also exercises cancellation while the editor's scheduler is paused.
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while fixture.viewport.terrainEditing.isSourceBusy, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(!fixture.viewport.terrainEditing.isSourceBusy)
            // Keep failed Red attempts clean by allowing their unnecessary rollback to finish.
            try await support.finish(fixture)
        }
        #expect(fixture.viewport.terrainEditing.sourceFailure == nil)
        #expect(fixture.viewport.sceneContent == content)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count)
        #expect(try FileManager.default.subpathsOfDirectory(atPath: fixture.root.path).sorted() == files)
        #expect(owner.components[MeshTerrain3DSourceSurface.self]?.asset.compiled?.inputKey == original)
        #expect(root.components[Transform.self]?.position.x == 0)
        #expect(root.components[MeshTerrain3DProposedPose.self] == nil)
        #expect(owner.components[MeshTerrain3DEdit.self] == nil)
        #expect(root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
    }

    func joinedFixture(_ support: EditorTerrainSourceViewportTests, grouped: Bool = false) async throws
        -> (EditorTerrainSourceViewportTests.Fixture, String, String) {
        let fixture = try await support.fixture()
        fixture.viewport.terrainEditing.creationBackend = .mesh
        fixture.viewport.terrainEditing.noise.amplitude = 0
        fixture.viewport.terrainEditing.sourceActions?.create()
        try await support.finish(fixture)
        let terrainID = try #require(fixture.viewport.selectedEditorID)
        var model = try #require(fixture.viewport.sceneModel)
        let parent = grouped ? model.addEntity(template: .empty, parentID: nil).id : nil
        let source = model.addEntity(template: .model3D, parentID: parent)
        let index = try #require(model.entities.firstIndex { $0.id == source.id })
        model.entities[index].components[EditorBuiltInComponentType.mesh3D]?["size"] = .double(2)
        fixture.viewport.sceneModel = model
        fixture.viewport.publishTerrainDocument()
        _ = fixture.viewport.reloadSceneRuntimeIfReady()
        fixture.viewport.selectedEditorID = source.id
        fixture.viewport.terrainEditing.dockTab = "Joining"
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            if try await fixture.app.withWorldAccess({ fixture.viewport.runtimeEntity(for: terrainID)?.components[MeshTerrain3DSourceSurface.self] != nil }) { break }
        }
        fixture.viewport.terrainEditing.sourceActions?.join?()
        try await support.finish(fixture)
        try #require(fixture.viewport.runtimeEntity(for: source.id)?.components[MeshTerrain3DBinding.self] != nil)
        return (fixture, terrainID, source.id)
    }

    @Test("Dragging a joined source stages its pose and saves the rebuilt terrain in one history edit")
    func joinedSourceDragSavesTerrainAndPoseTogether() async throws {
        let support = EditorTerrainSourceViewportTests()
        let fixture = try await support.fixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.viewport.terrainEditing.creationBackend = .mesh
        fixture.viewport.terrainEditing.noise.amplitude = 0
        fixture.viewport.terrainEditing.sourceActions?.create()
        try await support.finish(fixture)
        let terrainID = try #require(fixture.viewport.selectedEditorID)
        var model = try #require(fixture.viewport.sceneModel)
        let source = model.addEntity(template: .model3D, parentID: nil)
        let index = try #require(model.entities.firstIndex { $0.id == source.id })
        model.entities[index].components[EditorBuiltInComponentType.mesh3D]?["size"] = .double(2)
        fixture.viewport.sceneModel = model
        fixture.viewport.publishTerrainDocument()
        _ = fixture.viewport.reloadSceneRuntimeIfReady()
        fixture.viewport.selectedEditorID = source.id
        fixture.viewport.terrainEditing.dockTab = "Joining"
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            try await support.pump(fixture, frames: 1)
            if try await fixture.app.withWorldAccess({ fixture.viewport.runtimeEntity(for: terrainID)?.components[MeshTerrain3DSourceSurface.self] != nil }) { break }
        }
        fixture.viewport.terrainEditing.sourceActions?.join?()
        try await support.finish(fixture)
        let root = try #require(fixture.viewport.runtimeEntity(for: source.id))
        let owner = try #require(fixture.viewport.runtimeEntity(for: terrainID))
        try #require(root.components[MeshTerrain3DBinding.self] != nil)
        let previous = try #require(fixture.viewport.sceneModel?.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let oldURI = try EditorTerrainSourcePayload.decode(previous).source
        let oldFile = try EditorTerrainResource.resolve(oldURI, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let oldData = try Data(contentsOf: oldFile)
        let count = fixture.workbench.sceneUndoHistory["terrain"]?.count ?? 0
        fixture.viewport.setActiveTool(.translate)
        let gizmo = try #require(fixture.viewport.transformGizmo())
        let start = try #require(gizmo.shapes.first { $0.handle == .x }?.points.last)
        let end = try #require(fixture.viewport.project(gizmo.origin + Vector3(gizmo.worldLength + 3, 0, 0), size: fixture.viewport.viewportSize))
        try #require(fixture.viewport.beginTransformDragIfNeeded(at: start, button: .left))
        #expect(fixture.viewport.updateTransformDrag(to: end))
        // A UI input safe point must still expose the previous coherent geometry and source pose.
        #expect(root.components[Transform.self]?.position.x == 0)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 1)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count)
        let movedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < movedDeadline {
            try await support.pump(fixture, frames: 1)
            if let pose = root.components[Transform.self], abs(pose.position.x - 3) < 0.001,
                root.components[MeshTerrain3DProposedPose.self] == nil, root.components[MeshTerrain3DBindingStatus.self]?.phase == .applied { break }
        }
        #expect(root.components[MeshTerrain3DBindingStatus.self]?.error == nil)
        #expect(owner.components[MeshTerrain3DEditStatus.self]?.error == nil)
        #expect(abs((root.components[Transform.self]?.position.x ?? 0) - 3) < 0.001)
        #expect(try owner.components[MeshTerrain3DSourceSurface.self]?.queries?.raycast(.init(origin: [0, 5, 0], direction: [0, -1, 0]))?.position.y == 0)
        fixture.viewport.endTransformDrag()
        try await support.finish(fixture)
        #expect(fixture.workbench.sceneUndoHistory["terrain"]?.count == count + 1)
        let changed = try #require(fixture.workbench.activeSceneDocument?.sceneModel)
        let payload = try #require(changed.entities.first { $0.id == terrainID }?.components[EditorBuiltInComponentType.terrain3DSource])
        let uri = try EditorTerrainSourcePayload.decode(payload).source
        #expect(uri != oldURI)
        let file = try EditorTerrainResource.resolve(uri, sourceURL: fixture.scene, resourceRootURL: fixture.root)
        let manifest = try TerrainManifestAsset(data: Data(contentsOf: file))
        let name = try #require(manifest.meshDocumentFileName)
        let saved = try MeshTerrainDocumentAsset(data: Data(contentsOf: file.deletingLastPathComponent().appendingPathComponent(name)))
        _ = try saved.acceptedCompiledProduct()
        #expect(abs((saved.document.modifiers.first?.transform.origin.x ?? 0) - 3) < 0.001)
        let posePayload = try #require(changed.entities.first { $0.id == source.id }?.components[EditorBuiltInComponentType.transform])
        let pose = try #require(EditorComponentPayloadDecoder.decode(Transform.self, payload: posePayload) as? Transform)
        #expect(abs(pose.position.x - 3) < 0.001)
        #expect(try Data(contentsOf: oldFile) == oldData)
    }
}
