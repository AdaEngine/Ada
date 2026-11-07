@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import AdaScriptCompilerCore
import Foundation
import Math
import Testing

@testable import AdaEditor

extension EditorAnimationAuthoringTests {
    @Test func animationControlStyleActiveTogglesKeepTheirAccentAfterClicking() async throws {
        let graph = EditorAnimationGraphModel()
        graph.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        graph.selectedNodeID = "Clip1"
        let graphView = UIContainerView(rootView: EditorAnimationGraphEditor(model: graph, presentation: .inspector).theme(.adaEditor))
        graphView.frame = Rect(x: 0, y: 0, width: 380, height: 600); graphView.bounds.size = graphView.frame.size
        await settlePoseInspector(graphView)
        #expect(try animationControlHasAccent(graphView, identifier: "AdaEditor.AnimationGraph.Loop"))
        _ = try graphView.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AnimationGraph.Loop"))
        await settlePoseInspector(graphView)
        #expect(try !animationControlHasAccent(graphView, identifier: "AdaEditor.AnimationGraph.Loop"))

        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let timeline = UIContainerView(rootView: EditorAnimationTimeline(workspace: fixture.workspace).theme(.adaEditor))
        timeline.frame = Rect(x: 0, y: 0, width: 1200, height: 400); timeline.bounds.size = timeline.frame.size
        await settlePoseInspector(timeline)
        for id in ["AdaEditor.AnimationTimeline.SelectedOnly", "AdaEditor.AnimationTimeline.AnimatedOnly"] {
            #expect(try !animationControlHasAccent(timeline, identifier: id))
            _ = try timeline.uiTapNode(matching: .accessibilityIdentifier(id))
            await settlePoseInspector(timeline)
            #expect(try animationControlHasAccent(timeline, identifier: id), "Active timeline filter must retain a filled accent.")
            _ = try timeline.uiTapNode(matching: .accessibilityIdentifier(id))
            await settlePoseInspector(timeline)
            #expect(try !animationControlHasAccent(timeline, identifier: id))
        }
    }

    @Test func animationControlStyleGraphActionsHaveVisibleSurfacesAtRest() async throws {
        let graph = EditorAnimationGraphModel()
        graph.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        let container = UIContainerView(rootView: EditorAnimationGraphEditor(model: graph).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 380)
        container.bounds.size = container.frame.size
        await settlePoseInspector(container)
        let button = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.AnimationGraph.Add.clip"))
        let context = UIGraphicsContext()
        button.draw(with: context)
        #expect(context.getDrawCommands().contains { command in
            if case let .drawPath(_, _, .fill(color)) = command { return color == EditorThemeColors.dark.surface }
            return false
        }, "An idle graph action must draw a visible button surface, before hovering.")
    }

    @Test func animationControlStyleInspectorShowsAxisBadgesAndOverflowIndicator() async throws {
        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.workspace.timeline.selectNode(try #require(fixture.workspace.timeline.nodes.first { $0.name == "UpperArm.L" }).id)
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 600)
        container.bounds.size = container.frame.size
        await settlePoseInspector(container)
        let field = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.Animation.Pose.rotation.0"))
        var ancestor: ViewNode? = field
        while ancestor != nil, !(ancestor is ScrollViewNode) { ancestor = ancestor?.parent }
        let scroll = try #require(ancestor as? ScrollViewNode)
        #expect(!scroll.scrollIndicatorRects.isEmpty, "Overflowing animation Inspector must expose a scroll indicator.")
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.rotation"))
        await settlePoseInspector(container)
        let row = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.Animation.Pose.rotation"))
        let context = UIGraphicsContext()
        row.draw(with: context)
        for color in [Color(red: 0.78, green: 0.24, blue: 0.28), Color(red: 0.24, green: 0.60, blue: 0.31),
                      Color(red: 0.22, green: 0.43, blue: 0.82), Color(red: 0.57, green: 0.32, blue: 0.76)] {
            #expect(context.getDrawCommands().contains { command in
                if case let .drawPath(_, _, .fill(fill)) = command { return fill == color }
                return false
            }, "Quaternion components must have the same colored X/Y/Z/W badges as Transform Inspector.")
        }
    }

    @Test func finalWorkspaceClosingKeepsAnUnkeyedPoseAvailableForTheDecision() async throws {
        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        model.selectNode(try #require(model.nodes.first { $0.name == "UpperArm.L" }).id)
        try model.setPose(.translation, values: [1, 2, 3])
        fixture.workbench.closeDocument(id: fixture.workspace.document.id)
        #expect(fixture.workbench.openDocuments.contains { $0.id == fixture.workspace.document.id })
        #expect(fixture.workbench.animationWorkspaces[fixture.workspace.document.id] === fixture.workspace)
        #expect(model.hasUnkeyedPose)
    }

    @Test func poseFlowEulerEditingPreservesTheOtherAxes() async throws {
        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        let index = try #require(model.nodes.firstIndex { $0.name == "UpperArm.L" })
        model.selectNode(model.nodes[index].id)
        let original = Quat.euler([0.3, 0.5, 0.7]).normalized
        try model.setPose(.rotation, values: [original.x, original.y, original.z, original.w])
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 900); container.bounds.size = container.frame.size
        await settlePoseInspector(container)
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.RotationMode"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.RotationMode"))
        await settlePoseInspector(container)
        try await editPoseField("rotation.0", text: "45", in: container)
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.Apply.rotation"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.Apply.rotation"))
        let actual = try #require(fixture.workspace.preview.capturedAnimationPlayer()).poses[index].rotation
        let expected = Quat.euler([Float.pi / 4, 0.5, 0.7]).normalized
        #expect(abs(actual.dot(expected)) > 0.99999)
    }

    @Test func poseFlowMultiBoneComponentEditPreservesEachBonesOtherComponents() async throws {
        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        let left = try #require(model.nodes.firstIndex { $0.name == "UpperArm.L" })
        let right = try #require(model.nodes.firstIndex { $0.name == "UpperArm.R" })
        model.selectNode(model.nodes[left].id)
        try model.setPose(.translation, values: [1, 2, 3])
        model.selectNode(model.nodes[right].id)
        try model.setPose(.translation, values: [4, 5, 6])
        model.selectedNodes = [model.nodes[left].id, model.nodes[right].id]
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 900); container.bounds.size = container.frame.size
        await settlePoseInspector(container)
        try await editPoseField("translation.0", text: "7", in: container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.Apply.translation"))
        let player = try #require(fixture.workspace.preview.capturedAnimationPlayer())
        #expect(player.poses[left].translation == [7, 2, 3])
        #expect(player.poses[right].translation == [7, 5, 6])
    }

    @Test func poseFlowLibraryActionsRejectUnkeyedPoseWithoutReplacingItsTarget() async throws {
        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        model.selectNode(try #require(model.nodes.first { $0.name == "UpperArm.L" }).id)
        try model.setPose(.translation, values: [1, 2, 3])
        let before = fixture.document.library
        let clipID = fixture.document.selectedClipID
        fixture.workspace.clipName = "Another pose"
        do { try await fixture.workspace.extract(fromRest: true); Issue.record("Creating a clip must wait for the unkeyed pose decision.") }
        catch { #expect(error is AnimationAuthoringError) }
        #expect(fixture.workspace.library === fixture.document)
        #expect(fixture.document.library == before)
        #expect(fixture.document.selectedClipID == clipID)
        let other = try fixture.service.create("Assets/Other.animlib", library: AnimationLibrary(binding: before.binding, clips: before.clips))
        try other.save(expectedRevision: other.revision)
        fixture.workspace.libraryPath = other.relativePath
        #expect(throws: AnimationAuthoringError.self) { try fixture.workspace.openLibrary() }
        #expect(fixture.workspace.library === fixture.document)
        #expect(model.hasUnkeyedPose)
    }

    @Test func poseFlowExternalPreviewCannotMoveAnUnkeyedPoseToAnotherSecond() async throws {
        let fixture = try await poseWorkspaceFixture()
        defer { withExtendedLifetime(fixture.world) {}; fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        let node = try #require(model.nodes.first { $0.name == "UpperArm.L" })
        model.selectNode(node.id)
        try model.setPose(.translation, values: [1, 2, 3])
        let clipID = try #require(fixture.document.selectedClipID)
        do {
            _ = try await fixture.service.execute(.init(action: .preview, path: fixture.document.relativePath, clipID: clipID, time: 0.75), workbench: fixture.workbench)
            fixture.workspace.applyRequestedPreview()
        } catch { #expect(error is AnimationAuthoringError) }
        #expect(abs(model.time - 0.25) < 0.000001)
        try model.insertKeys(channels: [.translation])
        let track = try #require(fixture.document.library.clips.first { $0.id == clipID }?.tracks.first { $0.nodeID == node.id && $0.channel == .translation })
        #expect(track.keys.contains { abs($0.time - 0.25) < 0.000001 && $0.value == [1, 2, 3] })
        #expect(!track.keys.contains { abs($0.time - 0.75) < 0.000001 && $0.value == [1, 2, 3] })
    }

    @Test func visualWorkspaceReconnectPreservesWeightsAndMasksAndUndoesOnce() throws {
        let model = EditorAnimationGraphModel()
        let mask = AnimationGraph.Mask(defaultWeight: 0, joints: [.init(nodeIndex: 0, weight: 0.4, includesDescendants: true)])
        let original = AnimationGraph(root: "Output", nodes: [
            .init(id: "Clip1", clip: "Walk"),
            .init(id: "Output", kind: .blend, inputs: [.init(node: "Clip1", weight: 0.25, mask: mask)]),
            .init(id: "Additive1", kind: .additive, inputs: []),
        ])
        model.graph = original
        let geometry = EditorNodeCanvasGeometry(nodes: model.canvasItems, pan: .zero, zoom: 1)
        let from = try #require(geometry.port(.init(node: "Output", port: "0", isOutput: false)))
        let to = try #require(geometry.port(.init(node: "Additive1", port: "new", isOutput: false)))
        let pointer = model.canvasInteraction()
        pointer.drag(from: from, to: to, geometry: geometry, wires: model.canvasWires, selection: [], state: model.canvas)
        pointer.end(at: to, geometry: geometry)
        #expect(model.graph.nodes[2].inputs.first?.weight == 0.25)
        #expect(model.graph.nodes[2].inputs.first?.mask == mask)
        model.undoCanvas()
        #expect(model.graph == original)
    }

    @Test func visualWorkspaceNodeDeletionAndStaleWireAreAtomic() {
        let model = EditorAnimationGraphModel()
        let original = AnimationGraph(root: "Output", nodes: [
            .init(id: "A", clip: "Walk"), .init(id: "B", clip: "Idle"), .init(id: "C", clip: "Jump"),
            .init(id: "Output", kind: .blend, inputs: [.init(node: "A"), .init(node: "B"), .init(node: "C")]),
        ])
        model.graph = original
        model.selectedNodeID = "A"
        model.removeSelectedNode()
        model.undoCanvas()
        #expect(model.graph == original)
        model.selectedWire = model.canvasWires.first { $0.source.node == "B" }
        model.editNode("Output") { $0.inputs.removeFirst() }
        model.deleteCanvasSelection()
        #expect(model.graph.nodes.last?.inputs.map(\.node) == ["B", "C"])
    }

    @Test func visualWorkspaceShowsContextualInspectorAndCommonSkeletalRuler() async throws {
        let fixture = try animationWorkspaceFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.service.extract(path: "Assets/Robot.animlib", modelPath: fixture.asset.relativePath,
            clipName: "Walk", name: "Timeline")
        fixture.workspace.start()
        fixture.workspace.preview.cancel()
        fixture.workspace.library = document
        fixture.workspace.preview.asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: fixture.asset.absolutePath ?? "").asset)
        fixture.workspace.configureLoadedAsset()
        let container = UIContainerView(rootView: HStack {
            EditorAnimationAssetPanel(workspace: fixture.workspace, service: fixture.service)
            EditorContextualInspector(document: .asset(fixture.asset), workbench: fixture.workbench,
                sceneInspectorViewModel: EditorInspectorSidebarViewModel(), resourceRootURL: fixture.root)
                .frame(width: 300)
        }.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 420)
        container.bounds.size = container.frame.size
        for _ in 0..<4 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Animation.Inspector")).isEmpty)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AnimationTimeline.Ruler")).isEmpty)
        guard let ruler = container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AnimationTimeline.Ruler")).first else { return }
        let rect = ruler.absoluteFrame
        let point = Point(rect.minX + rect.width * 0.25, rect.midY)
        for phase in [MouseEvent.Phase.began, .ended] {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
        let inputSnapshot = container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AnimationTimeline.Input")).map(\.absoluteFrame)
        let hitType = container.uiHitTest(at: point)?.node.nodeType
        #expect(fixture.workspace.preview.playbackTime > 0,
                "Ruler: \(rect), hit: \(String(describing: hitType)), input: \(inputSnapshot)")
        #expect(!fixture.workspace.preview.playsAnimation)
    }

    @Test func animationGraphRendersPoseCardsOnTheSharedNodeCanvas() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AnimationCanvas")))
        }
        let model = EditorAnimationGraphModel()
        model.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        let container = UIContainerView(rootView: EditorAnimationGraphEditor(model: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 380)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas.Node.Clip1")).isEmpty)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas.Node.Output")).isEmpty)
    }

    @Test func documentedToolKeepsTheSecondClipDuringTrackAndKeyInspection() async throws {
        let fixture = try animationWorkspaceFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.service.extract(path: "Assets/Robot.animlib", modelPath: fixture.asset.relativePath,
            clipName: "Walk", name: "First clip")
        _ = try await fixture.service.extract(path: document.relativePath, modelPath: fixture.asset.relativePath,
            clipName: "Walk", name: "Second clip", expectedRevision: document.revision)
        let clip = try #require(document.library.clips.last)
        try #require(document.library.clips.count == 2)
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Documentation/Examples/StudioTools/AnimationHelper/AnimationHelper.ada")
        let source = AdaScriptSource(path: "Tools/AnimationHelper/AnimationHelper.ada", source: try String(contentsOf: url, encoding: .utf8))
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        func performAndPoll(_ action: String, inputs: [String: AdaScriptSchemaField.Value] = [:]) async throws {
            _ = try runtime.perform(action, inputs: inputs, scene: nil)
            let job = try #require(runtime.takeAnimationJobs().first)
            let payload = try await fixture.service.execute(job.request, workbench: fixture.workbench)
            let data = try EditorAnimationAuthoringService.responseData(["status": "completed", "result": payload])
            try runtime.completeAnimationJob(job.id, responseJSON: String(decoding: data, as: UTF8.self))
            _ = try runtime.perform("poll", inputs: [:], scene: nil)
        }
        try await performAndPoll("inspectTracks", inputs: ["path": .string(document.relativePath), "clipID": .string(clip.id)])
        try #require(runtime.values["clipID"] == .string(clip.id))
        guard case let .string(trackID) = runtime.values["trackID"] else { Issue.record("A rotation track must be selected."); return }
        let track = try #require(clip.tracks.first { $0.id == trackID })
        try await performAndPoll("inspectKeys")
        #expect(runtime.values["clipID"] == .string(clip.id))
        #expect(runtime.values["keyID"] == .string(try #require(track.keys.first).id))
    }

    @Test func documentedToolSamplesLaterBonesThroughSmallPosePages() async throws {
        let fixture = try animationWorkspaceFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.service.extract(path: "Assets/Robot.animlib", modelPath: fixture.asset.relativePath,
            clipName: "Walk", name: "Paged sample")
        let clip = try #require(document.library.clips.first)
        let nodes = document.library.binding.nodes
        let track = try #require(clip.tracks.filter { $0.channel == .rotation }.max { left, right in
            let leftIndex = nodes.firstIndex { $0.id == left.nodeID } ?? 0
            let rightIndex = nodes.firstIndex { $0.id == right.nodeID } ?? 0
            return leftIndex < rightIndex
        })
        let nodeIndex = try #require(nodes.firstIndex { $0.id == track.nodeID })
        try #require(nodeIndex >= 8)
        let time = try #require(track.keys.first).time
        let sampled = try document.library.sample(clipID: clip.id, at: time)
        let expected = sampled.poses[nodeIndex].rotation.z
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Documentation/Examples/StudioTools/AnimationHelper/AnimationHelper.ada")
        let source = AdaScriptSource(path: "Tools/AnimationHelper/AnimationHelper.ada", source: try String(contentsOf: url, encoding: .utf8))
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate()
        _ = try runtime.perform("sample", inputs: ["path": .string(document.relativePath), "clipID": .string(clip.id),
            "nodeID": .string(track.nodeID), "keyTime": .double(time), "sampledRotationZ": .double(-99)], scene: nil)
        var pages = 0
        repeat {
            let job = try #require(runtime.takeAnimationJobs().first)
            try #require((job.request.limit ?? 256) <= 8)
            #expect(job.request.offset == pages * 8)
            let payload = try await fixture.service.execute(job.request, workbench: fixture.workbench)
            let data = try EditorAnimationAuthoringService.responseData(["status": "completed", "result": payload])
            try runtime.completeAnimationJob(job.id, responseJSON: String(decoding: data, as: UTF8.self))
            _ = try runtime.perform("poll", inputs: [:], scene: nil)
            pages += 1
        } while runtime.values["job"] != .string("") && pages < 256
        #expect(pages > 1)
        #expect(runtime.values["job"] == .string(""))
        guard case let .double(actual) = runtime.values["sampledRotationZ"] else {
            Issue.record("The real Tool must read the target bone from a later page.")
            return
        }
        #expect(abs(actual - Double(expected)) < 0.00001)
    }

    @Test func assetWorkspaceSharesTheCenterPlayerAcrossModesAndServiceEdits() async throws {
        let fixture = try animationWorkspaceFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.workspace
        #expect(fixture.workbench.animationWorkspace(for: fixture.asset) === workspace)
        let model = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: fixture.asset.absolutePath ?? "").asset)
        workspace.preview.asset = model
        workspace.configureLoadedAsset()
        workspace.sourceClip = "Walk"
        try await workspace.extract(fromRest: false)
        let document = try #require(workspace.library)
        #expect(try fixture.service.open(document.relativePath) === document)
        // This is the state an agent's first-open preview request installs before the viewport mounts.
        document.previewTime = 0.25
        document.previewSerial += 1
        workspace.configureLoadedAsset()
        let world = World(name: "Shared model center")
        _ = model.instantiate(in: world)
        workspace.preview.bind(to: world)
        #expect(abs((try #require(workspace.preview.capturedAnimationPlayer())).time - 0.25) < 0.000001)
        let camera = workspace.camera
        for mode in [EditorAnimationAssetWorkspace.Mode.graph, .keys, .clips, .keys] {
            workspace.mode = mode
            workspace.applyModePreview()
            #expect(workspace.camera === camera)
            #expect(abs((try #require(workspace.preview.capturedAnimationPlayer())).time - 0.25) < 0.000001)
        }
        let clip = try #require(document.library.clips.first)
        _ = try fixture.service.apply(path: document.relativePath, expectedRevision: document.revision,
            operations: [.init(kind: .configureClip, clipID: clip.id, name: "Shared edit")])
        workspace.refreshLibrary()
        #expect(workspace.library === document)
        #expect(workspace.library?.library.clips.first?.name == "Shared edit")
        #expect(document.canUndo)
        #expect(try Data(contentsOf: URL(fileURLWithPath: fixture.asset.absolutePath ?? "")) == fixture.original)
    }

    @Test func authoredPlacementKeepsOneShotAndRejectsStaleSavedLibraries() async throws {
        let fixture = try animationWorkspaceFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = try await fixture.service.extract(path: "Assets/Animations/Robot.animlib", modelPath: fixture.asset.relativePath,
            clipName: "Walk", name: "One shot")
        let clip = try #require(document.library.clips.first)
        try document.apply([.init(kind: .configureClip, clipID: clip.id, repeats: false)], expectedRevision: document.revision)
        try document.save(expectedRevision: document.revision)
        let sceneModel = EditorSceneModel.default(projectName: "Placement")
        let content = try sceneModel.encodedYAML()
        let sceneID = "scene:Assets/Main.ascn"
        fixture.workbench.open(.scene(.init(id: sceneID, title: "Main.ascn", relativePath: "Assets/Main.ascn",
            absolutePath: fixture.root.appendingPathComponent("Assets/Main.ascn").path, content: content, lastSavedContent: content,
            isReadOnly: false, sceneModel: sceneModel, errorMessage: nil, isDirty: false, statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content))))
        #expect(try await fixture.workbench.addAnimatedModelAsset(fixture.asset, to: sceneID,
            animation: document.library.runtimeName(for: clip.id), autoplay: true,
            repeats: try #require(document.library.clips.first).repeats, graph: nil, library: document))
        let placed = try #require(fixture.workbench.sceneDocument(id: sceneID))
        let payload = try #require(placed.sceneModel?.entities.last?.components[EditorBuiltInComponentType.model3DSource])
        #expect(payload["repeats"] == .bool(false))
        #expect(payload["animationLibraries"] == .array([.string("@res://Animations/Robot.animlib")]))
        let prior = placed.content
        let saved = try Data(contentsOf: document.url)
        try Data("externally changed".utf8).write(to: document.url)
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await fixture.workbench.addAnimatedModelAsset(fixture.asset, to: sceneID,
                animation: document.library.runtimeName(for: clip.id), autoplay: true, repeats: false, graph: nil, library: document)
        }
        #expect(fixture.workbench.sceneDocument(id: sceneID)?.content == prior)
        try saved.write(to: document.url)
        try fixture.service.close(document.relativePath)
        await #expect(throws: AnimationAuthoringError.self) {
            _ = try await fixture.workbench.addAnimatedModelAsset(fixture.asset, to: sceneID,
                animation: document.library.runtimeName(for: clip.id), autoplay: true, repeats: false, graph: nil, library: document)
        }
        #expect(fixture.workbench.sceneDocument(id: sceneID)?.content == prior)
    }

    @Test func animatorHasRoomForEditingAndRemembersItsOwnResize() {
        let viewModel = EditorViewModel(project: nil)
        defer { viewModel.studioTools.close() }
        let animator = EditorToolStripItem(identifier: "animator", title: "Animator", icon: "")
        let logs = EditorToolStripItem(identifier: "logs", title: "Logs", icon: "")
        viewModel.toolStrip.selectLeftBottomTool(animator)
        viewModel.showBottomPanel = true
        let state = EditorWorkspaceResizeState()
        let size = Size(width: 1200, height: 900)
        #expect(state.layout(in: size, viewModel: viewModel).bottomPanelHeight == 380)
        state.resize(.bottom, translation: Size(width: 0, height: 80), in: size, viewModel: viewModel)
        state.endDrag()
        #expect(state.layout(in: size, viewModel: viewModel).bottomPanelHeight == 300)
        viewModel.toolStrip.selectLeftBottomTool(logs)
        #expect(state.layout(in: size, viewModel: viewModel).bottomPanelHeight == 180)
        viewModel.toolStrip.selectLeftBottomTool(animator)
        #expect(state.layout(in: size, viewModel: viewModel).bottomPanelHeight == 300)
    }
}

@MainActor
private func animationWorkspaceFixture() throws -> (root: URL, workbench: EditorWorkbenchViewModel,
    service: EditorAnimationAuthoringService, asset: EditorAssetDocument, workspace: EditorAnimationAssetWorkspace, original: Data) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("AnimationWorkspace-\(UUID())")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Assets"), withIntermediateDirectories: true)
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Tests/AdaEngineTests/Fixtures/SkeletalGardenAssets/GardenRobot.glb")
    let original = try Data(contentsOf: source)
    let url = root.appendingPathComponent("Assets/Robot.glb")
    try original.write(to: url)
    let workbench = EditorWorkbenchViewModel()
    workbench.configureAnimationAuthoring(projectURL: root, assetsURL: root.appendingPathComponent("Assets"))
    let asset = EditorAssetDocument(id: "asset:Assets/Robot.glb", title: "Robot.glb", relativePath: "Assets/Robot.glb", absolutePath: url.path,
        assetReference: "@res://Robot.glb", kind: .model3D, fileExtension: "glb", byteCount: nil, modifiedAt: nil, errorMessage: nil)
    workbench.open(.asset(asset))
    return (root, workbench, try #require(workbench.animationService), asset, workbench.animationWorkspace(for: asset), original)
}

@MainActor private func poseWorkspaceFixture() async throws -> (root: URL, workbench: EditorWorkbenchViewModel,
    service: EditorAnimationAuthoringService, workspace: EditorAnimationAssetWorkspace, document: EditorAnimationLibraryDocument, world: World) {
    let fixture = try animationWorkspaceFixture()
    let document = try await fixture.service.extract(path: "Assets/Robot.animlib", modelPath: fixture.asset.relativePath, clipName: "Walk", name: "Pose edit")
    fixture.workspace.start(); fixture.workspace.preview.cancel()
    let asset = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: fixture.asset.absolutePath ?? "").asset)
    fixture.workspace.library = document
    fixture.workspace.libraryPath = document.relativePath
    document.selectedClipID = document.library.clips.first?.id
    fixture.workspace.preview.asset = asset
    fixture.workspace.configureLoadedAsset()
    let world = World(name: "Real pose preview")
    _ = asset.instantiate(in: world)
    fixture.workspace.preview.bind(to: world)
    fixture.workspace.timeline.seek(0.25)
    return (fixture.root, fixture.workbench, fixture.service, fixture.workspace, document, world)
}

@MainActor private func settlePoseInspector<Content: View>(_ container: UIContainerView<Content>) async {
    for _ in 0..<6 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
}

@MainActor private func animationControlHasAccent<Content: View>(_ container: UIContainerView<Content>, identifier: String) throws -> Bool {
    let node = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier(identifier))
    let context = UIGraphicsContext()
    node.draw(with: context)
    return context.getDrawCommands().contains { command in
        if case let .drawPath(_, _, .fill(color)) = command { return color == EditorThemeColors.dark.blue.opacity(0.16) }
        return false
    }
}

@MainActor private func editPoseField<Content: View>(_ suffix: String, text: String, in container: UIContainerView<Content>) async throws {
    let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Animation.Pose." + suffix)
    _ = try container.uiScrollToNode(matching: selector)
    _ = try container.uiTapNode(matching: selector)
    try #require(container.uiPerformTextEditingCommand(.selectAll))
    for character in text {
        container.onTextInputEvent(TextInputEvent(window: RID(), text: String(character), action: .insert, time: 0))
        await settlePoseInspector(container)
    }
}
