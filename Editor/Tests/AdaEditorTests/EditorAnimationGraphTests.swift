import Foundation
import Math
import Testing

@_spi(Internal) @testable import AdaApp
@testable import AdaEditor
@_spi(AdaEngine) @testable import AdaEngine
import AdaInput
@_spi(Internal) @testable import AdaRender
@_spi(Internal) import AdaUI
import AdaUtils

@MainActor
@Suite(.serialized)
struct EditorAnimationGraphTests {
    init() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("Graph editor controls use the real AdaUI event path")
    func graphControls() async throws {
        let pose = SkeletalJointPose()
        let author = EditorAnimationGraphModel()
        author.rig = try .init(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix, name: "Root")])
        let track = try SkeletalAnimationTrack(nodeIndex: 0, path: .translation, interpolation: .linear, times: [0, 1], values: [.zero, .zero])
        author.clips = [.init(name: "Move", tracks: [track])]
        author.graph = EditorAnimationGraphModel.defaultGraph(clip: "Move")
        let container = UIContainerView(rootView: EditorAnimationGraphEditor(model: author))
        container.frame = Rect(x: 0, y: 0, width: 960, height: 360)
        container.bounds.size = container.frame.size
        func settle() async throws {
            for _ in 0..<3 {
                try await Task.sleep(for: .milliseconds(1))
                container.update(1 / 60)
                container.layoutIfNeeded()
            }
        }
        try await settle()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Add.additive"))
        #expect(author.selectedNode?.kind == .additive)
        try await settle()
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.AddInput"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.AddInput"))
        #expect(author.selectedNode?.inputs.count == 2)
        try await settle()
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Weight.0"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Weight.0"))
        #expect(container.uiPerformTextEditingCommand(.selectAll))
        for character in ["0", ".", "2", "5"] {
            container.onTextInputEvent(TextInputEvent(window: RID(), text: character, action: .insert, time: 0))
            try await settle()
        }
        #expect(author.selectedNode?.inputs[0].weight == 0.25, "Fractional weights must retain intermediate text such as 0.")
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Mask.1"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Mask.1"))
        #expect(author.selectedNode?.inputs[1].mask != nil)
        try await settle()
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.AddJoint.1"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.AddJoint.1"))
        #expect(author.selectedNode?.inputs[1].mask?.joints.first?.nodeIndex == 0)
        try await settle()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Node.Clip1"))
        try await settle()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.AddEvent"))
        #expect(author.selectedNode?.events.first?.name == "Event")
    }

    @Test("Graph authoring saves structured scene data, reopens in runtime and supports undo/redo")
    func graphSceneRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AnimationGraph-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let modelURL = directory.appendingPathComponent("TwoBoneRibbon.glb")
        let engine = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        try FileManager.default.copyItem(at: engine.appendingPathComponent("Demos/SkeletalGarden/Assets/TwoBoneRibbon.glb"), to: modelURL)
        let sceneURL = directory.appendingPathComponent("Main.ascn")
        var scene = EditorSceneModel.default(projectName: "Graph")
        let entity = scene.addEntity(template: .importedModel3D, parentID: scene.rootEntityID)
        let index = try #require(scene.entities.firstIndex { $0.id == entity.id })
        scene.entities[index].components[EditorBuiltInComponentType.model3DSource] = [
            "source": .string("@res://TwoBoneRibbon.glb"), "animation": .string("Bend"), "autoplay": .bool(false), "repeats": .bool(true),
        ]
        let content = try scene.encodedYAML()
        try content.write(to: sceneURL, atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(
            id: "Scene", 
            title: "Main", 
            relativePath: "Main.ascn", 
            absolutePath: sceneURL.path,
            content: content, 
            lastSavedContent: content, 
            sceneModel: scene, 
            isDirty: false, 
            loadSummary: .init(entityCount: 0, warnings: [])
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: "Scene")
        let asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: modelURL.path).asset)
        let author = EditorAnimationGraphModel()
        author.configure(asset: asset)
        author.editNode("Clip1") { $0.events.append(.init(time: 0.2, name: "Step", payload: "right")) }
        author.editNode("Output") { $0.inputs[0].mask = .init(defaultWeight: 0, joints: [.init(nodeIndex: 1)]) }
        #expect(author.validationMessage == nil)
        let graph = try #require(author.validGraph)
        let target = EditorSkeletalAnimationTarget(
            documentID: "Scene", 
            entityID: entity.id,
            source: .init(source: "@res://TwoBoneRibbon.glb"), 
            sceneURL: sceneURL
        )
        #expect(try workbench.setAnimationGraph(graph, target: target, autoplay: true))
        #expect(workbench.saveAllDocuments())
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: sceneURL, encoding: .utf8))
        let saved = try #require(reopened.entities.first { $0.id == entity.id }?.components[EditorBuiltInComponentType.model3DSource])
        #expect(try EditorAnimationGraphPayload.decode(saved["animationGraph"]) == graph)
        let world = World()
        let result = EditorSceneFileLoader.load(content: try reopened.encodedYAML(), into: world, sourceURL: sceneURL, resourceRootURL: directory)
        #expect(result.warnings.isEmpty, Comment(rawValue: result.warnings.joined(separator: "\n")))
        let root = try #require(world.getEntities().first { $0.components[ModelAnimation3DComponent.self] != nil })
        var animation = try #require(root.components[ModelAnimation3DComponent.self])
        #expect(animation.player.graph == graph && animation.player.isPlaying)
        animation.player.advance(by: 0.3, evaluatePose: false)
        #expect(animation.player.drainGraphEvents().map(\.marker.name) == ["Step"])
        #expect(workbench.performDocumentHistory(redo: false))
        let undone = try #require(workbench.activeSceneDocument?.sceneModel?.entities.first { $0.id == entity.id })
        #expect(undone.components[EditorBuiltInComponentType.model3DSource]?["animationGraph"] == nil)
        #expect(workbench.performDocumentHistory(redo: true))
        let redone = try #require(workbench.activeSceneDocument?.sceneModel?.entities.first { $0.id == entity.id })
        #expect(try EditorAnimationGraphPayload.decode(redone.components[EditorBuiltInComponentType.model3DSource]?["animationGraph"]) == graph)

        let preview = EditorModelAssetPreviewModel()
        preview.asset = asset
        let previewWorld = World()
        let previewRoot = try Model3DSource(animationGraph: graph).instantiate(asset, in: previewWorld, under: previewWorld.spawn("Preview"))
        preview.animationGraph = graph
        preview.bind(to: previewWorld)
        preview.seekGraph(to: 0.4)
        preview.playsAnimation = false
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.time == 0.4)
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.isPlaying == false)
        preview.playsAnimation = true
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.time == 0.4)
        var editedGraph = graph
        editedGraph.nodes[1].inputs[0].weight = 0.5
        preview.animationGraph = editedGraph
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.time == 0.4, "Editing graph weights must preserve the preview clock")
        #expect(previewRoot.components[ModelAnimation3DComponent.self]?.player.graph == editedGraph)
    }

    @Test("Node editor rejects cycles and disconnected invalid graphs before preview/application")
    func invalidDraftIsVisible() throws {
        let pose = SkeletalJointPose()
        let author = EditorAnimationGraphModel()
        author.rig = try .init(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix)])
        let track = try SkeletalAnimationTrack(nodeIndex: 0, path: .translation, interpolation: .linear, times: [0, 1], values: [.zero, .zero])
        author.clips = [.init(name: "Move", tracks: [track])]
        author.graph = EditorAnimationGraphModel.defaultGraph(clip: "Move")
        #expect(author.validGraph != nil)
        author.editNode("Output") { $0.inputs[0].node = "Output" }
        #expect(author.validationMessage?.contains("cycle") == true)
        #expect(author.validGraph == nil)
        author.editNode("Output") { $0.inputs[0].node = "Clip1" }
        author.selectedNodeID = "Output"
        author.addNode(.additive)
        let added = author.selectedNodeID
        #expect(author.selectedNode?.kind == .additive)
        author.removeSelectedNode()
        #expect(!author.graph.nodes.contains { $0.id == added })
        #expect(author.validGraph != nil)
    }
}
