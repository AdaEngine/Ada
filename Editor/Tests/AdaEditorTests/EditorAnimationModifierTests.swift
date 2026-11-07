import AdaEngine
import AdaScriptCompilerCore
import Foundation
import Math
import Testing

@testable import AdaEditor

extension EditorAnimationAuthoringTests {
    @Test
    func modifierDraftNeverAutosavesThroughTheEditorDocumentCallback() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.document.save(expectedRevision: fixture.document.revision)
        let original = try Data(contentsOf: fixture.document.url)
        let editor = EditorViewModel(project: .init(name: "IK", path: fixture.root.path), autosaveDelay: .milliseconds(10))
        defer { editor.studioTools.close() }
        let service = try #require(editor.workbench.animationService)
        let document = try service.openModifiers(fixture.document.relativePath)
        var value = try #require(document.stack.modifiers.first)
        value.influence = 0.25
        _ = try await service.execute(.init(action: .modifierApply, path: document.relativePath, expectedRevision: document.revision,
            modifierOperations: [.init(kind: .update, modifierID: value.id, modifier: value)]), workbench: editor.workbench)
        try await Task.sleep(for: .milliseconds(100))
        #expect(document.isDirty)
        let unchanged = try Data(contentsOf: document.url) == original
        #expect(unchanged)
        #expect(editor.autosaveTasks["asset:" + document.relativePath] == nil)
    }

    @Test
    func ikSceneBindingRejectsStaleRevisionsAndCommitsOneUndoStepFromNullBindings() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.document.save(expectedRevision: fixture.document.revision)
        var model = EditorSceneModel.default(projectName: "IK")
        model.entities.append(.init(id: "robot", name: "Robot", enabled: true, parent: nil, components: [
            EditorBuiltInComponentType.model3DSource: ["source": .string("@res://Robot.glb"), "modifierBindings": .null]
        ]))
        model.entities.append(.init(id: "target", name: "Target", enabled: true, parent: nil, components: [:]))
        let content = try model.encodedYAML(), path = "Assets/Main.ascn", id = "scene:" + path
        fixture.workbench.open(.scene(.init(id: id, title: "Main.ascn", relativePath: path,
            absolutePath: fixture.root.appendingPathComponent(path).path, content: content, lastSavedContent: content,
            isReadOnly: false, sceneModel: model, errorMessage: nil, isDirty: false, statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content))))
        let bindings = ["arm": AnimationIKBinding3D(target: .init(entity: "target", point: [1, 2, 3]))]
        var request = AnimationAuthoringRequest(action: .modifierBind, path: fixture.document.relativePath,
            expectedRevision: fixture.document.revision, scenePath: path, entityID: "robot", sceneRevision: "stale", modifierBindings: bindings)
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await fixture.service.execute(request, workbench: fixture.workbench)
        }
        #expect(fixture.workbench.sceneDocument(id: id)?.content == content)
        #expect(fixture.workbench.sceneUndoHistory[id]?.isEmpty != false)
        request.sceneRevision = EditorAgentSceneToolService.revision(for: content)
        _ = try await fixture.service.execute(request, workbench: fixture.workbench)
        let bound = try #require(fixture.workbench.sceneDocument(id: id))
        let payload = try #require(bound.sceneModel?.entities.first(where: { $0.id == "robot" })?.components[EditorBuiltInComponentType.model3DSource])
        #expect(payload["animationModifiers"] == .string("@res://Arm.animmod"))
        #expect(fixture.workbench.sceneUndoHistory[id]?.count == 1)
        #expect(fixture.workbench.performDocumentHistory(redo: false))
        #expect(fixture.workbench.sceneDocument(id: id)?.content == content)
        #expect(fixture.workbench.performDocumentHistory(redo: true))
        #expect(fixture.workbench.sceneDocument(id: id)?.content == bound.content)
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await fixture.service.execute(request, workbench: fixture.workbench)
        }
        #expect(fixture.workbench.sceneDocument(id: id)?.content == bound.content)
    }

    @Test
    func inspectorSceneDraftRestoresBindingsOffsetsAndLoadedRevision() throws {
        let draft = EditorIKSceneBindingDraft()
        let original = AnimationIKBinding3D(target: .init(entity: "hand-target", point: [0.1, -0.2, 0.3]), pole: .init(entity: "elbow-pole", point: [2, 3, 4]))
        draft.load(original, sceneRevision: "scene-before")
        #expect(draft.targetEntity == "hand-target")
        #expect(draft.poleEntity == "elbow-pole")
        #expect(try draft.binding() == original)
        #expect(draft.sceneRevision == "scene-before")
        draft.targetEntity = ""
        #expect(try draft.binding().target == nil)
        draft.load(.init(target: .init(point: [7, 8, 9])), sceneRevision: "other-modifier")
        #expect(draft.poleEntity.isEmpty)
        #expect(try draft.binding() == .init(target: .init(point: [7, 8, 9])))
        #expect(draft.targetUsesModelPoint)
        draft.targetOffset = ["1", "2", "3"]
        #expect(try draft.binding().target?.point == Vector3(1, 2, 3))
        draft.targetUsesModelPoint = false
        #expect(try draft.binding().target == nil)
        draft.load(nil, sceneRevision: "fresh")
        #expect(try draft.binding() == .init())
        #expect(!draft.targetUsesModelPoint && !draft.poleUsesModelPoint)
        draft.poleUsesModelPoint = true
        draft.poleOffset = ["4", "5", "6"]
        #expect(try draft.binding().pole == .init(point: [4, 5, 6]))
    }

    @Test
    func modelTabRoutesModifierUndoAndRedoToTheSharedDraft() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.workspace.timeline.inspectorMode = "modifiers"
        let before = fixture.document.stack
        var value = try #require(before.modifiers.first)
        value.influence = 0.25
        try fixture.workspace.editModifiers([.init(kind: .update, modifierID: value.id, modifier: value)])
        #expect(fixture.workbench.performDocumentHistory(redo: false))
        #expect(fixture.document.stack == before)
        #expect(fixture.workbench.performDocumentHistory(redo: true))
        #expect(fixture.document.stack.modifiers.first?.influence == 0.25)
    }

    @Test
    func closingSavedIKTabPreservesAttachedModelDraftAndSubsequentEdits() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.document.save(expectedRevision: fixture.document.revision)
        let id = "asset:" + fixture.document.relativePath
        fixture.workbench.closeDocument(id: id)
        #expect(!fixture.workbench.openDocuments.contains { $0.id == id })
        #expect(!fixture.document.isDiscarded)
        var value = try #require(fixture.document.stack.modifiers.first)
        value.influence = 0.25
        try fixture.workspace.editModifiers([.init(kind: .update, modifierID: value.id, modifier: value)])
        #expect(fixture.document.isDirty)
        #expect(fixture.workbench.openDocuments.contains { $0.id == id && $0.isDirty })
        #expect(fixture.service.modifierDocuments[fixture.document.url.path] === fixture.document)
    }

    @Test
    func invalidIKSelectionDoesNotCreateOrAttachADraft() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.workspace.modifiers = nil
        fixture.workspace.modifierPath = "Assets/Rejected.animmod"
        fixture.workspace.timeline.selectedNodes = [try #require(fixture.document.stack.modifiers.first?.joints.first)]
        #expect(throws: (any Error).self) { try fixture.workspace.addModifier(.twoBone) }
        #expect(fixture.workspace.modifiers == nil)
        #expect(!fixture.service.modifierDocuments.values.contains { $0.relativePath == "Assets/Rejected.animmod" })
    }

    @Test
    func ikDraftIsSharedByWorkspaceAgentAndRealToolWithExplicitSaveAndUndo() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = fixture.document
        let start = document.stack
        let cfg = try #require(start.modifiers.first)
        var changed = cfg
        changed.influence = 0.5
        try fixture.workspace.editModifiers([.init(kind: .update, modifierID: cfg.id, modifier: changed)])
        let uiSample = try await fixture.service.execute(.init(action: .modifierSample, path: document.relativePath, limit: 8), workbench: fixture.workbench)
        #expect(document.stack.modifiers[0].influence == 0.5)
        #expect(!FileManager.default.fileExists(atPath: document.url.path))
        _ = try await fixture.service.execute(.init(action: .modifierUndo, path: document.relativePath, expectedRevision: document.revision), workbench: fixture.workbench)
        #expect(document.stack == start)
        try document.redo(expectedRevision: document.revision)
        let example = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Documentation/Examples/StudioTools/IKHelper/IKHelper.ada")
        let source = AdaScriptSource(path: "IKHelper.ada", source: try String(contentsOf: example, encoding: .utf8))
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        _ = try runtime.perform("sample", inputs: [:], scene: nil)
        let job = try #require(runtime.takeAnimationJobs().first)
        let toolSample = try await fixture.service.execute(job.request, workbench: fixture.workbench)
        let response = try JSONSerialization.data(withJSONObject: ["status": "completed", "result": toolSample])
        try runtime.completeAnimationJob(job.id, responseJSON: String(decoding: response, as: UTF8.self))
        _ = try runtime.perform("poll", inputs: [:], scene: nil)
        let first = try JSONSerialization.data(withJSONObject: uiSample["poses"] ?? [], options: .sortedKeys)
        let second = try JSONSerialization.data(withJSONObject: toolSample["poses"] ?? [], options: .sortedKeys)
        let equalPages = first == second
        #expect(equalPages)
        _ = try await fixture.service.execute(.init(action: .modifierSave, path: document.relativePath, expectedRevision: document.revision), workbench: fixture.workbench)
        let reopened = try EditorAnimationAuthoringService(projectURL: fixture.root, assetsURL: fixture.root.appendingPathComponent("Assets")).openModifiers(document.relativePath)
        #expect(reopened.stack == document.stack)
        #expect(try Data(contentsOf: fixture.modelURL) == fixture.original)
    }

    @Test
    func ikGizmoDragCommitsOneHistoryEntryAndCancelRestoresTheSavedDraft() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.workspace, document = fixture.document
        let asset = try #require(workspace.preview.asset)
        let world = World()
        let root = asset.instantiate(in: world)
        root.components[Transform.self] = workspace.preview.normalizationTransform
        workspace.preview.bind(to: world)
        workspace.camera.attach(to: world, bounds: workspace.preview.normalizedBounds)
        workspace.camera.setViewportSize(Size(width: 800, height: 600))
        workspace.timeline.inspectorMode = "modifiers"
        workspace.selectedModifierID = document.stack.modifiers.first?.id
        let initial = document.stack
        let target = try #require(initial.modifiers.first).target
        let point = (workspace.preview.normalizationTransform.matrix * Vector4(target, 1)).xyz
        let screen = try #require(workspace.camera.project(point))
        func send(_ phase: MouseEvent.Phase, x: Float) {
            #expect(workspace.handleModifierInput(MouseEvent(window: RID(), button: .left,
                mousePosition: Point(screen.x + x, screen.y), phase: phase, modifierKeys: [], time: 0), camera: workspace.camera))
        }
        let revision = document.revision
        send(.began, x: 0)
        for offset in 1...10 { send(.changed, x: Float(offset) * 2) }
        #expect(document.revision == revision)
        send(.ended, x: 20)
        #expect(document.stack != initial)
        try document.undo(expectedRevision: document.revision)
        #expect(document.stack == initial)
        send(.began, x: 0); send(.changed, x: 20); send(.cancelled, x: 20)
        #expect(document.stack == initial)
        #expect(workspace.preview.capturedAnimationPlayer()?.poseModifiers == initial.modifiers)
        withExtendedLifetime(world) {}
    }

    @Test
    func staleIKTransactionsAndExternalDiskWritesPreserveTheCurrentDraft() async throws {
        let fixture = try await modifierFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = fixture.document
        let before = document.stack
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await fixture.service.execute(.init(action: .modifierApply, path: document.relativePath, expectedRevision: "stale",
                modifierOperations: [.init(kind: .remove, modifierID: "arm")]), workbench: fixture.workbench)
        }
        #expect(document.stack == before)
        try document.save(expectedRevision: document.revision)
        try Data("external".utf8).write(to: document.url)
        #expect(throws: AnimationAuthoringError.self) { try document.save(expectedRevision: document.revision) }
        #expect(try Data(contentsOf: document.url) == Data("external".utf8))
    }
}

@MainActor
private func modifierFixture() async throws -> (root: URL, modelURL: URL, original: Data, workbench: EditorWorkbenchViewModel,
    service: EditorAnimationAuthoringService, workspace: EditorAnimationAssetWorkspace, document: EditorAnimationModifierDocument) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("IKRequests-" + UUID().uuidString)
    let assets = root.appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
    let bytes = try Data(contentsOf: source), modelURL = assets.appendingPathComponent("Robot.glb")
    try bytes.write(to: modelURL)
    let workbench = EditorWorkbenchViewModel()
    workbench.configureAnimationAuthoring(projectURL: root, assetsURL: assets)
    let service = try #require(workbench.animationService)
    let assetDocument = EditorAssetDocument(id: "asset:Assets/Robot.glb", title: "Robot.glb", relativePath: "Assets/Robot.glb", absolutePath: modelURL.path,
        assetReference: "@res://Robot.glb", kind: .model3D, fileExtension: "glb", byteCount: nil, modifiedAt: nil, errorMessage: nil)
    workbench.open(.asset(assetDocument))
    let workspace = workbench.animationWorkspace(for: assetDocument)
    workspace.preview.asset = try AssetsManager.loadSync(ModelAsset3D.self, at: modelURL.path).asset
    workspace.configureLoadedAsset()
    let rig = try #require(workspace.preview.asset?.animationRig)
    let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
    let end = try #require(rig.nodes.indices.first { index in
        guard let middle = rig.nodes[index].parentIndex, let root = rig.nodes[middle].parentIndex,
              [root, middle, index].allSatisfy({ rig.nodes[$0].restPose != nil }) else { return false }
        return (player.globalTransforms[index].origin - player.globalTransforms[middle].origin).length > 1e-5
            && (player.globalTransforms[middle].origin - player.globalTransforms[root].origin).length > 1e-5
    })
    let middle = try #require(rig.nodes[end].parentIndex), first = try #require(rig.nodes[middle].parentIndex)
    let document = try service.createModifiers("Assets/Arm.animmod", binding: AnimationRigBinding(rig: rig, sourceAsset: "Assets/Robot.glb"))
    var stack = document.stack
    try stack.apply([.init(kind: .add, modifier: .init(id: "arm", kind: .twoBone, joints: [first, middle, end].map { "node-\($0)" },
        target: player.globalTransforms[end].origin))])
    try document.commit(stack, expectedRevision: document.revision)
    workspace.modifierPath = document.relativePath
    try workspace.openModifiers()
    return (root, modelURL, bytes, workbench, service, workspace, document)
}
