@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

extension EditorAnimationAuthoringTests {
    @Test func anOpenLibraryCanCreateAnotherClipOnItsSourceRig() async throws {
        let fixture = try graphRequestFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.service.extract(path: "Assets/Robot.animlib", modelPath: fixture.workspace.document.relativePath,
            clipName: "Walk", name: "First")
        try document.save(expectedRevision: document.revision)
        let asset = EditorAssetDocument(id: "asset:" + document.relativePath, title: "Robot.animlib", relativePath: document.relativePath,
            absolutePath: document.url.path, assetReference: "@res://Robot.animlib", kind: .animationLibrary,
            fileExtension: "animlib", byteCount: nil, modifiedAt: nil, errorMessage: nil)
        fixture.workbench.open(.asset(asset))
        let workspace = fixture.workbench.animationWorkspace(for: asset)
        defer { workspace.cancel() }
        workspace.library = document
        workspace.libraryPath = document.relativePath
        workspace.preview.asset = fixture.workspace.preview.asset
        workspace.configureLoadedAsset()
        workspace.clipName = "New pose"
        try await workspace.extract(fromRest: true)
        #expect(document.library.clips.count == 2)
        #expect(document.library.clips.last?.name == "New pose")
        #expect(document.selectedClipID == document.library.clips.last?.id)
        #expect(document.isDirty)
        #expect(try Data(contentsOf: fixture.modelURL) == fixture.original)
    }

    @Test func denseTimelineUsesBoundedTimeQueriesAndRecordsRealPlayerScrubLatency() async throws {
        let fixture = try graphRequestFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.service.extract(path: "Assets/Dense.animlib", modelPath: fixture.workspace.document.relativePath,
            clipName: "Walk", name: "Dense")
        let node = try #require(document.library.binding.nodes.first { $0.name == "UpperArm.L" })
        let keys = (0..<80_000).map { AnimationLibraryKey(id: "key-\($0)", time: Double($0) / 1000, value: [Float($0 % 100) / 100, 0, 0]) }
        let dense = AnimationLibraryClip(id: "dense", name: "Dense", duration: 80,
            tracks: [.init(id: "dense-track", nodeID: node.id, channel: .translation, keys: keys)])
        try document.apply([.init(kind: .removeClip, clipID: try #require(document.library.clips.first).id),
            .init(kind: .createClip, clip: dense)], expectedRevision: document.revision)
        document.selectedClipID = dense.id
        fixture.workspace.library = document
        fixture.workspace.mode = .keys
        fixture.workspace.refreshLibrary()
        let world = World(name: "Dense timeline input")
        _ = try #require(fixture.workspace.preview.asset).instantiate(in: world)
        fixture.workspace.preview.bind(to: world)
        let model = fixture.workspace.timeline
        model.pixelsPerSecond = 100
        model.snap = 0
        let row = try #require(model.rows.first { $0.nodeID == node.id })
        #expect(model.keys(in: row, timeRange: 10...10.01).count == 11)
        let input = EditorAnimationTimelineInputView(frame: Rect(x: 0, y: 0, width: 800, height: 350))
        input.model = model
        let started = Date.timeIntervalSinceReferenceDate
        for index in 0..<100 {
            let point = Point(EditorAnimationTimeline.labelsWidth + Float(index % 50 + 1), 10)
            for phase in [MouseEvent.Phase.began, .changed, .ended] {
                input.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
            }
        }
        let milliseconds = (Date.timeIntervalSinceReferenceDate - started) * 1000 / 100
        print("Dense timeline: 80000 keys, 100 real-player ruler gestures, mean milliseconds per gesture: \(milliseconds)")
        #expect(abs(try #require(fixture.workspace.preview.capturedAnimationPlayer()).time - 0.5) < 0.000001)
        #expect(model.error.isEmpty)
        withExtendedLifetime(world) {}
    }

    @Test func documentedGraphToolEditsTheSameOpenWorkspaceAndKeepsLibraryRevisionSeparate() async throws {
        let fixture = try graphRequestFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Documentation/Examples/StudioTools/AnimationHelper/AnimationHelper.ada")
        let source = AdaScriptSource(path: "AnimationHelper.ada", source: try String(contentsOf: url, encoding: .utf8))
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        for action in ["inspectGraph", "halfWeightGraph", "previewGraph"] {
            _ = try runtime.perform(action, inputs: [:], scene: nil)
            let job = try #require(runtime.takeAnimationJobs().first)
            let payload = try await fixture.service.execute(job.request, workbench: fixture.workbench)
            let data = try EditorAnimationAuthoringService.responseData(["status": "completed", "result": payload])
            try runtime.completeAnimationJob(job.id, responseJSON: String(decoding: data, as: UTF8.self))
            _ = try runtime.perform("poll", inputs: [:], scene: nil)
            #expect(runtime.values["graphRevision"] == .string(fixture.workspace.graph.revision))
            #expect(runtime.values["revision"] == .string(""))
        }
        #expect(fixture.workspace.graph.graph.nodes.last?.inputs.first?.weight == 0.5)
        #expect(fixture.workspace.mode == .graph)
    }

    @Test func graphRequestsRejectUnsafeIDsAndMaskWorkBeforePublishing() throws {
        let model = EditorAnimationGraphModel()
        model.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        let original = model.graph, history = model.undoStack.count, revision = model.revision
        var duplicate = original
        duplicate.nodes.append(duplicate.nodes[0])
        #expect(throws: AnimationAuthoringError.self) { try model.applyGraph(duplicate, expectedRevision: revision) }
        #expect(model.graph == original && model.undoStack.count == history && model.revision == revision)
        let pose = SkeletalJointPose()
        model.rig = try .init(nodes: (0..<512).map { .init(parentIndex: $0 == 0 ? nil : $0 - 1, restPose: pose, restMatrix: pose.matrix) })
        let mask = AnimationGraph.Mask(joints: (0..<256).map { .init(nodeIndex: $0) })
        // Missing root keeps the baseline safe: it fails validation before actually expanding this mask.
        let expensive = AnimationGraph(root: "Missing", nodes: [.init(id: "Walk", clip: "Walk"),
            .init(id: "Output", kind: .blend, inputs: [.init(node: "Walk", mask: mask)])])
        #expect(throws: AnimationAuthoringError.self) { try model.applyGraph(expensive, expectedRevision: model.revision) }
    }

    @Test func graphRequestsShareCanvasHistoryWithRealToolJobsAndRejectStaleEdits() async throws {
        let fixture = try graphRequestFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.workspace, service = fixture.service, workbench = fixture.workbench
        let path = workspace.document.relativePath
        let response = try await service.execute(.init(action: .graphInspect, path: path), workbench: workbench)
        let revision = try #require(response["revision"] as? String)
        #expect(response["ready"] as? Bool == true)
        let original = workspace.graph.graph
        let source = AdaScriptSource(path: "Graph.ada", source: """
            @tool(id: "test.sharedGraph", api: 2, platforms: ["windows", "macos"], permissions: ["editor.animations.read", "editor.animations.write"])
            class GraphTool {
                @export var revision = "";
                func activate(editor) { editor.addPanel(id: "main", title: "Graph", location: "right", ui: "Panel.ui"); }
                func apply(editor) {
                    editor.animations.submit(["action": "graphApply", "path": "Assets/Robot.glb", "expectedRevision": revision,
                        "graph": ["root": "Output", "nodes": [
                            ["id": "Walk", "kind": "clip", "clip": "Walk", "speed": 1, "repeats": true, "inputs": [], "events": []],
                            ["id": "Output", "kind": "blend", "clip": "", "speed": 1, "repeats": true,
                             "inputs": [["node": "Walk", "weight": 0.25]], "events": []]]]]);
                }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        _ = try runtime.perform("apply", inputs: ["revision": .string(revision)], scene: nil)
        let job = try #require(runtime.takeAnimationJobs().first)
        _ = try await service.execute(job.request, workbench: workbench)
        #expect(workspace.graph.graph.nodes.last?.inputs.first?.weight == 0.25)
        #expect(workspace.graph.validGraph != nil)
        await #expect(throws: AnimationAuthoringError.self) { _ = try await service.execute(job.request, workbench: workbench) }
        _ = try await service.execute(.init(action: .graphUndo, path: path, expectedRevision: workspace.graph.revision), workbench: workbench)
        #expect(workspace.graph.graph == original)
        _ = try await service.execute(.init(action: .graphRedo, path: path, expectedRevision: workspace.graph.revision), workbench: workbench)
        #expect(workspace.graph.graph.nodes.last?.inputs.first?.weight == 0.25)
        workspace.graph.beginCanvasTransaction()
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await service.execute(.init(action: .graphUndo, path: path, expectedRevision: workspace.graph.revision), workbench: workbench)
        }
        workspace.graph.cancelCanvasTransaction()
        #expect(try Data(contentsOf: fixture.modelURL) == fixture.original)
    }

    @Test func graphRequestsRejectUnkeyedPreviewAndBindAsOneSceneTransaction() async throws {
        let fixture = try graphRequestFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let sceneModel = EditorSceneModel.default(projectName: "Graph binding")
        let content = try sceneModel.encodedYAML(), sceneID = "scene:Assets/Main.ascn"
        fixture.workbench.open(.scene(.init(id: sceneID, title: "Main.ascn", relativePath: "Assets/Main.ascn",
            absolutePath: fixture.root.appendingPathComponent("Assets/Main.ascn").path, content: content, lastSavedContent: content,
            isReadOnly: false, sceneModel: sceneModel, errorMessage: nil, isDirty: false,
            loadSummary: EditorSceneFileLoader.summary(from: content))))
        #expect(fixture.workbench.addModelAsset(fixture.workspace.document, to: sceneID, animation: "Walk", autoplay: true))
        let scene = try #require(fixture.workbench.sceneDocument(id: sceneID))
        let entity = try #require(scene.sceneModel?.entities.first { $0.components[EditorBuiltInComponentType.model3DSource] != nil })
        let request = AnimationAuthoringRequest(action: .graphBind, path: fixture.workspace.document.relativePath,
            expectedRevision: fixture.workspace.graph.revision, scenePath: scene.relativePath, entityID: entity.id,
            sceneRevision: EditorAgentSceneToolService.revision(for: scene.content))
        _ = try await fixture.service.execute(request, workbench: fixture.workbench)
        let bound = try #require(fixture.workbench.sceneDocument(id: sceneID))
        #expect(try EditorAnimationGraphPayload.decode(bound.sceneModel?.entities.first { $0.id == entity.id }?
            .components[EditorBuiltInComponentType.model3DSource]?["animationGraph"]) == fixture.workspace.graph.graph)
        await #expect(throws: AnimationAuthoringError.self) { _ = try await fixture.service.execute(request, workbench: fixture.workbench) }
        #expect(fixture.workbench.performDocumentHistory(redo: false))
        #expect(fixture.workbench.sceneDocument(id: sceneID)?.content == scene.content)
        let rig = try #require(fixture.workspace.graph.rig)
        fixture.workspace.graph.rig = try SkeletalRig(nodes: rig.nodes.enumerated().map { index, node in
            .init(parentIndex: node.parentIndex, restPose: node.restPose, restMatrix: node.restMatrix,
                name: index == 0 ? "Different root" : node.name, morphRestWeights: node.morphRestWeights)
        })
        do {
            _ = try await fixture.service.execute(request, workbench: fixture.workbench)
            Issue.record("Matching clip names cannot authorize an index-based graph on a different rig.")
        } catch { #expect((error as? AnimationAuthoringError)?.code == .incompatibleRig) }
        fixture.workspace.timeline.poseValues["test:translation"] = [1, 2, 3]
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await fixture.service.execute(.init(action: .graphPreview, path: fixture.workspace.document.relativePath,
                expectedRevision: fixture.workspace.graph.revision), workbench: fixture.workbench)
        }
    }
}

@MainActor private func graphRequestFixture() throws -> (root: URL, modelURL: URL, original: Data,
    workbench: EditorWorkbenchViewModel, service: EditorAnimationAuthoringService, workspace: EditorAnimationAssetWorkspace) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("GraphRequests-" + UUID().uuidString)
    let assets = root.appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
    let bytes = try Data(contentsOf: source), url = assets.appendingPathComponent("Robot.glb")
    try bytes.write(to: url)
    let workbench = EditorWorkbenchViewModel()
    workbench.configureAnimationAuthoring(projectURL: root, assetsURL: assets)
    let document = EditorAssetDocument(id: "asset:Assets/Robot.glb", title: "Robot.glb", relativePath: "Assets/Robot.glb", absolutePath: url.path,
        assetReference: "@res://Robot.glb", kind: .model3D, fileExtension: "glb", byteCount: nil, modifiedAt: nil, errorMessage: nil)
    workbench.open(.asset(document))
    let workspace = workbench.animationWorkspace(for: document)
    workspace.preview.asset = try AssetsManager.loadSync(ModelAsset3D.self, at: url.path).asset
    workspace.configureLoadedAsset()
    return (root, url, bytes, workbench, try #require(workbench.animationService), workspace)
}
