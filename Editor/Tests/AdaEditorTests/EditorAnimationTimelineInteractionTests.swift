@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

extension EditorAnimationAuthoringTests {
    @Test func nativeCurveFieldsCommitOneUndoAndShareTheirPayloadWithTheAgentAndRealToolVM() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = fixture.document, model = fixture.workspace.timeline
        try document.apply([.init(kind: .configureTrack, clipID: "walk", trackID: "ta", interpolation: .bezier)], expectedRevision: document.revision)
        fixture.workspace.refreshLibrary()
        model.selectKey(.init(track: "ta", key: "a0"))
        let original = document.library
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 3000); container.bounds.size = container.frame.size
        func settle() async { for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() } }
        await settle()
        for (suffix, text) in [("Time", "0"), ("Value", "0.5")] {
            let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Animation.Key.Bezier.Outgoing." + suffix)
            _ = try container.uiScrollToNode(matching: selector)
            _ = try container.uiTapNode(matching: selector)
            try #require(container.uiPerformTextEditingCommand(.selectAll))
            for character in text {
                container.onTextInputEvent(TextInputEvent(window: RID(), text: String(character), action: .insert, time: 0))
                await settle()
            }
        }
        #expect(document.library == original, "Numeric drafts must not change playback before Apply.")
        let apply = UINodeSelector.accessibilityIdentifier("AdaEditor.Animation.Key.Curve.Apply")
        _ = try container.uiScrollToNode(matching: apply); _ = try container.uiTapNode(matching: apply)
        #expect(model.error.isEmpty)
        let changed = document.library
        let key = try #require(changed.clips[0].tracks.first { $0.id == "ta" }?.keys.first)
        #expect(key.curve?.outgoing?.first == .init(timeOffset: 0, valueOffset: 0.5))
        #expect(try changed.sample(clipID: "walk", at: 0.25).poses[1].translation.x > 0.4)
        try document.undo(expectedRevision: document.revision)
        #expect(document.library == original)
        try document.redo(expectedRevision: document.revision)
        #expect(document.library == changed)
        try document.save(expectedRevision: document.revision)
        #expect(try AnimationLibrary.decode(Data(contentsOf: document.url)) == changed)

        let source = AdaScriptSource(path: "Curves.ada", source: """
            @tool(id: "test.curves", api: 2, platforms: ["macos", "windows"], permissions: ["editor.animations.read", "editor.animations.write"])
            class Curves {
                func activate(editor) { editor.addPanel(id: "main", title: "Curves", location: "right", ui: "Panel.ui"); }
                func apply(editor) {
                    editor.animations.submit(["action": "apply", "path": "Assets/Tool.animlib", "expectedRevision": "test",
                        "operations": [["id": "curve", "kind": "key.put", "clipID": "walk", "trackID": "ta", "replaceExisting": true,
                            "key": ["id": "a0", "time": 0, "value": [0, 0, 0], "curve": ["easing": ["family": "linear", "direction": "inOut"],
                                "outgoing": [["timeOffset": 0, "valueOffset": 0.5], ["timeOffset": 0.3333333333333333, "valueOffset": 0],
                                             ["timeOffset": 0.3333333333333333, "valueOffset": 0]]]]]]]);
                }
            }
            """)
        let schema = try #require(AdaScriptSchemaParser.parseTools(sources: [source]).first)
        let runtime = try AdaScriptToolRuntime(sources: [source], schema: schema, grantedPermissions: schema.permissions)
        defer { runtime.deactivate() }
        try runtime.activate(); _ = try runtime.perform("apply", inputs: [:], scene: nil)
        let request = try #require(runtime.takeAnimationJobs().first).request
        let operations = try #require(request.operations)
        var fromTool = original
        try fromTool.apply(operations)
        #expect(fromTool == changed)
        // The agent and native Inspector use this same Codable request and production edit path.
        let decoded = try JSONDecoder().decode(AnimationAuthoringRequest.self, from: JSONEncoder().encode(request))
        var fromAgent = original
        try fromAgent.apply(try #require(decoded.operations))
        #expect(fromAgent == changed)
    }

    @Test func nativeCurveInspectorExposesEasingAndBezierFieldsAndKeyCaptureRetainsTheirData() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = fixture.document, model = fixture.workspace.timeline
        var track = try #require(document.library.clips[0].tracks.first)
        track.interpolation = .bezier
        track.keys[0].curve = .init(easing: .init(family: .elastic), outgoing: Array(repeating: .init(timeOffset: 0.1, valueOffset: 0), count: 3))
        try document.apply([.init(kind: .removeTrack, clipID: "walk", trackID: track.id),
                            .init(kind: .createTrack, clipID: "walk", track: track)], expectedRevision: document.revision)
        fixture.workspace.refreshLibrary()
        model.selectKey(.init(track: track.id, key: track.keys[0].id))
        model.seek(track.keys[0].time)
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 3000); container.bounds.size = container.frame.size
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        for id in ["Easing.Family", "Easing.Direction", "Easing.Amplitude", "Easing.Period", "Bezier.Outgoing.Time", "Bezier.Outgoing.Value", "Curve.Apply"] {
            #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Animation.Key." + id)).isEmpty)
        }
        try model.insertKeys(channels: [track.channel])
        #expect(document.library.clips[0].tracks.first { $0.id == track.id }?.keys.first?.curve == track.keys[0].curve)
    }

    @Test func inspectorCompletionChannelRowsInsertOnlyTheirChosenChannel() throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        model.expandedChannels = ["root", "b"]
        let input = EditorAnimationTimelineInputView(frame: Rect(x: 0, y: 0, width: 800, height: 600))
        input.model = model
        func select(_ node: String) throws {
            let row = try #require(model.rows.firstIndex { $0.nodeID == node && $0.channel == .rotation })
            let point = Point(80, EditorAnimationTimeline.rulerHeight + (Float(row) + 0.5) * EditorAnimationTimeline.rowHeight)
            for phase in [MouseEvent.Phase.began, .ended] {
                input.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
            }
        }
        try select("root")
        try model.insertKeys()
        #expect(fixture.document.library.clips[0].tracks.filter { $0.nodeID == "root" }.map(\.channel) == [.rotation])
        try select("b")
        model.seek(0.25)
        try model.insertKeys()
        #expect(fixture.document.library.clips[0].tracks.filter { $0.nodeID == "b" }.map(\.channel) == [.rotation])
    }

    @Test func inspectorCompletionUnanimatedNodeDoesNotExposeAnotherNodesTrack() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.workspace.timeline.selectNode("root")
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 1200); container.bounds.size = container.frame.size
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Animation.Track.Interpolation")).isEmpty)
        #expect(fixture.workspace.timeline.selectedTrack == nil)
        #expect(!fixture.document.canUndo)
    }

    @Test func inspectorCompletionRecoversAnExternalConflictAndDiscardsThroughTheSharedService() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let document = fixture.document
        try document.apply([.init(kind: .configureClip, clipID: "walk", name: "Dirty")], expectedRevision: document.revision)
        var external = document.library
        external.clips[0].name = "External"
        try external.encodedData().write(to: document.url)
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 340, height: 1200); container.bounds.size = container.frame.size
        func settle() async { for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() } }
        await settle()
        let reload = UINodeSelector.accessibilityIdentifier("AdaEditor.Animation.Library.DiscardReload")
        #expect(!container.uiFindNodes(matching: reload).isEmpty)
        guard !container.uiFindNodes(matching: reload).isEmpty else { return }
        _ = try container.uiScrollToNode(matching: reload)
        _ = try container.uiTapNode(matching: reload)
        #expect(document.library == external && !document.isDirty)
        try document.apply([.init(kind: .configureClip, clipID: "walk", name: "Discard me")], expectedRevision: document.revision)
        await settle()
        let discard = UINodeSelector.accessibilityIdentifier("AdaEditor.Animation.Library.Discard")
        _ = try container.uiScrollToNode(matching: discard)
        _ = try container.uiTapNode(matching: discard)
        #expect(document.isDiscarded)
        #expect(fixture.workspace.library == nil)
        #expect(fixture.workspace.service?.documents.isEmpty == true)
        #expect(try AnimationLibrary.decode(Data(contentsOf: document.url)) == external)
    }

    @Test func finalWorkspaceImplicitPositionsAndActiveGestureHistoryAreStable() throws {
        let model = EditorAnimationGraphModel()
        model.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        let graph = model.graph, history = model.undoStack.count
        let geometry = EditorNodeCanvasGeometry(nodes: model.canvasItems, pan: .zero, zoom: 1)
        let pointer = model.canvasInteraction(), start = Vector2(40, 15)
        pointer.drag(from: start, to: start + [80, 20], geometry: geometry, wires: model.canvasWires, selection: [], state: model.canvas)
        model.undoCanvas()
        #expect(model.graph == graph, "Undo is unavailable while a pointer transaction is active.")
        pointer.drag(from: start, to: start, geometry: geometry, wires: model.canvasWires, selection: ["Clip1"], state: model.canvas)
        pointer.end(at: start, geometry: geometry)
        #expect(model.positions.isEmpty)
        #expect(model.undoStack.count == history)
        #expect(model.graph == graph)
    }

    @Test func finalWorkspaceTrackFiltersAreReachableWithoutOpeningInspector() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let container = UIContainerView(rootView: EditorAnimationTimeline(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 800, height: 350); container.bounds.size = container.frame.size
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        for id in ["Filter", "SelectedOnly", "AnimatedOnly", "ChannelFilter"] {
            #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AnimationTimeline." + id)).isEmpty)
        }
    }

    @Test func visualRegressionReturningWireAndCardToOriginIsANoOp() throws {
        let model = EditorAnimationGraphModel()
        model.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        model.graph.nodes[1].inputs[0].weight = 0.3
        model.graph.nodes[1].inputs[0].mask = .init(defaultWeight: 0.2)
        model.positions = ["Clip1": [0, 0], "Output": [300, 0]]
        let before = model.graph, positions = model.positions, history = model.undoStack.count
        let geometry = EditorNodeCanvasGeometry(nodes: model.canvasItems, pan: .zero, zoom: 1)
        let port = try #require(geometry.port(.init(node: "Output", port: "0", isOutput: false)))
        let wire = model.canvasInteraction()
        wire.drag(from: port, to: port + [40, 40], geometry: geometry, wires: model.canvasWires, selection: [], state: model.canvas)
        wire.end(at: port, geometry: geometry)
        #expect(model.graph == before)
        #expect(model.undoStack.count == history)
        let pointer = model.canvasInteraction()
        let start = Vector2(40, 15)
        pointer.drag(from: start, to: start + [80, 20], geometry: geometry, wires: model.canvasWires, selection: [], state: model.canvas)
        pointer.drag(from: start, to: start, geometry: geometry, wires: model.canvasWires, selection: ["Clip1"], state: model.canvas)
        pointer.end(at: start, geometry: geometry)
        #expect(model.positions == positions)
        #expect(model.undoStack.count == history)
    }

    @Test func visualRegressionEscapeEndsTheActualRulerAndMarqueePointerCapture() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let container = UIContainerView(rootView: EditorAnimationTimeline(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 800, height: 350); container.bounds.size = container.frame.size
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        let ruler = try #require(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AnimationTimeline.Ruler")).first).absoluteFrame
        func mouse(_ phase: MouseEvent.Phase, _ point: Point) {
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
        func escape() { container.onKeyEvent(KeyEvent(window: RID(), keyCode: .escape, modifiers: [], status: .down, time: 0, isRepeated: false)) }
        let start = Point(ruler.minX + 50, ruler.midY)
        mouse(.began, start); mouse(.changed, start + Point(30, 0))
        escape()
        let time = fixture.workspace.timeline.time
        mouse(.changed, start + Point(150, 0)); mouse(.ended, start + Point(150, 0))
        #expect(fixture.workspace.timeline.time == time)
        let box = Point(ruler.maxX - 30, ruler.maxY + 10)
        mouse(.began, box); mouse(.changed, box + Point(-30, 40))
        escape()
        mouse(.changed, box + Point(-80, 80)); mouse(.ended, box + Point(-80, 80))
        #expect(fixture.workspace.timeline.marquee == nil)
        #expect(fixture.workspace.timeline.selectedKeys.isEmpty)
    }

    @Test func visualRegressionSmallWindowKeepsAMeaningfulModelArea() {
        let model = EditorViewModel(project: nil)
        defer { model.studioTools.close() }
        model.toolStrip.selectLeftBottomTool(.init(identifier: "animator", title: "Animator", icon: ""))
        model.showBottomPanel = true
        let layout = EditorWorkspaceResizeState().layout(in: Size(width: 1024, height: 550), viewModel: model)
        #expect(layout.mainPanelHeight >= 260)
        #expect(layout.bottomPanelHeight >= 220)
    }

    @Test func previewWorkspaceSettingsCurvesAndPoseFieldsAreRealPanels() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.workspace
        workspace.mode = .curves
        workspace.timeline.selectNode("a")
        workspace.timeline.selectedTrackID = "ta"
        workspace.timeline.inspectorMode = "preview"
        let container = UIContainerView(rootView: HStack {
            EditorAnimationTimeline(workspace: workspace)
            EditorAnimationInspector(workspace: workspace).frame(width: 300)
        }.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1200, height: 600)
        container.bounds.size = container.frame.size
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Animation.PreviewSettings")).isEmpty)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AnimationCurves.Editor")).isEmpty)
        workspace.timeline.inspectorMode = "selection"
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Animation.Pose.rotation")).isEmpty)
    }

    @Test func previewWorkspaceRemembersGraphAndPanelStateOnReopen() throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let workspace = fixture.workspace
        workspace.graph.graph = EditorAnimationGraphModel.defaultGraph(clip: "Walk")
        workspace.graph.positions["Clip1"] = [420, 180]
        workspace.timeline.modelPanelWidth = 280
        workspace.timeline.showsModelPanel = false
        workspace.timeline.selectedNodes = ["b"]
        workspace.mode = .graph
        workspace.cancel()
        let reopened = EditorAnimationAssetWorkspace(document: workspace.document, service: workspace.service)
        defer { reopened.cancel() }
        #expect(reopened.graph.graph == workspace.graph.graph)
        #expect(reopened.graph.positions == workspace.graph.positions)
        #expect(reopened.timeline.modelPanelWidth == 280)
        #expect(!reopened.timeline.showsModelPanel)
        #expect(reopened.timeline.selectedNodes == ["b"])
        #expect(reopened.mode == .graph)
    }

    @Test func previewWorkspaceInspectorRefreshesSameKeyAfterSharedEdits() async throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        fixture.workspace.timeline.selectKey(.init(track: "ta", key: "a0"))
        let container = UIContainerView(rootView: EditorAnimationInspector(workspace: fixture.workspace).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 800)
        container.bounds.size = container.frame.size
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        let replacement = AnimationLibraryKey(id: "a0", time: 0, value: [2, 0, 0])
        _ = try fixture.workspace.service?.apply(path: fixture.document.relativePath, expectedRevision: fixture.document.revision,
            operations: [.init(kind: .putKey, clipID: "walk", trackID: "ta", key: replacement, replaceExisting: true)])
        for _ in 0..<5 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Key.Update"))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Animation.Key.Update"))
        #expect(fixture.document.library.clips[0].tracks[0].keys[0].value == [2, 0, 0])
        #expect(fixture.workspace.timeline.error.isEmpty)
    }

    @Test func timelineCubicMorphDragIsOneUndoAndCollisionRollsBack() throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        let before = fixture.document.library
        model.expandedChannels = ["a"]
        model.snap = 0
        model.pixelsPerSecond = 100
        model.viewportSize = Size(width: 700, height: 300)
        let row = try #require(model.rows.firstIndex { $0.track?.id == "morph" })
        let input = EditorAnimationTimelineInputView(frame: Rect(x: 0, y: 0, width: 700, height: 300))
        input.model = model
        let from = Point(EditorAnimationTimeline.labelsWidth, EditorAnimationTimeline.rulerHeight + (Float(row) + 0.5) * EditorAnimationTimeline.rowHeight)
        for (phase, point) in [(MouseEvent.Phase.began, from), (.changed, from + Point(100, 0)), (.ended, from + Point(100, 0))] {
            input.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
        }
        #expect(model.error.isEmpty)
        #expect(fixture.document.library.clips[0].tracks[2].keys.map(\.time) == [0.5, 1])
        try fixture.document.undo(expectedRevision: fixture.document.revision)
        #expect(fixture.document.library == before)
        model.selectedKeys = [.init(track: "morph", key: "m0")]
        model.beginKeyDrag(); model.dragDelta = 0.5; model.endKeyDrag()
        #expect(!model.error.isEmpty)
        #expect(fixture.document.library == before)
    }

    @Test func timelineDragCannotEditAnotherDuplicatedClip() throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.document.apply([.init(kind: .duplicateClip, clipID: "walk", newID: "other", name: "Other")], expectedRevision: fixture.document.revision)
        let model = fixture.workspace.timeline
        model.selectedKeys = [.init(track: "ta", key: "a0")]
        model.beginKeyDrag()
        model.dragDelta = 0.25
        let before = fixture.document.library
        fixture.document.selectedClipID = "other"
        model.endKeyDrag()
        #expect(fixture.document.library == before)
        #expect(!model.error.isEmpty)
    }

    @Test func timelinePlainKeySelectionReplacesBoneScopeAndFiltersClampScroll() throws {
        let fixture = try timelineInteractionFixture()
        defer { fixture.workspace.cancel(); try? FileManager.default.removeItem(at: fixture.root) }
        let model = fixture.workspace.timeline
        model.selectKey(.init(track: "ta", key: "a0"))
        model.selectKey(.init(track: "tb", key: "b0"))
        #expect(model.selectedNodes == ["b"])
        model.selectKey(.init(track: "ta", key: "a0"), additive: true)
        #expect(model.selectedNodes == ["a", "b"])
        model.viewportSize = Size(width: 700, height: 300)
        model.verticalOffset = 10_000
        model.search = "Bone B"
        #expect(model.verticalOffset == 0)
        #expect(model.rows.contains { $0.nodeID == "b" })
    }
}

@MainActor
private func timelineInteractionFixture() throws -> (root: URL, workspace: EditorAnimationAssetWorkspace, document: EditorAnimationLibraryDocument) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TimelineInteraction-" + UUID().uuidString)
    let assets = root.appendingPathComponent("Assets")
    try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
    let nodes: [AnimationRigBinding.Node] = [
        .init(id: "root", name: "Root", restTranslation: .zero, restRotation: [0, 0, 0, 1], restScale: [1, 1, 1]),
        .init(id: "a", name: "Bone A", parentID: "root", restTranslation: .zero, restRotation: [0, 0, 0, 1], restScale: [1, 1, 1], morphRestWeights: [0]),
        .init(id: "b", name: "Bone B", parentID: "root", restTranslation: .zero, restRotation: [0, 0, 0, 1], restScale: [1, 1, 1]),
    ]
    let library = AnimationLibrary(binding: .init(sourceAsset: "Assets/Robot.glb", nodes: nodes), clips: [
        .init(id: "walk", name: "Walk", duration: 2, tracks: [
            .init(id: "ta", nodeID: "a", channel: .translation, keys: [.init(id: "a0", time: 0, value: [0, 0, 0]), .init(id: "a1", time: 1, value: [1, 0, 0])]),
            .init(id: "tb", nodeID: "b", channel: .rotation, keys: [.init(id: "b0", time: 0, value: [0, 0, 0, 1])]),
            .init(id: "morph", nodeID: "a", channel: .weights, interpolation: .cubicSpline, keys: [
                .init(id: "m0", time: 0, value: [0], incoming: [0], outgoing: [0]),
                .init(id: "m1", time: 0.5, value: [1], incoming: [0], outgoing: [0]),
            ]),
        ]),
    ])
    let service = EditorAnimationAuthoringService(projectURL: root, assetsURL: assets)
    let document = try service.create("Assets/Robot.animlib", library: library)
    try document.save(expectedRevision: document.revision)
    document.selectedClipID = "walk"
    let asset = EditorAssetDocument(id: "asset:Assets/Robot.glb", title: "Robot.glb", relativePath: "Assets/Robot.glb",
        absolutePath: assets.appendingPathComponent("Robot.glb").path, assetReference: "@res://Robot.glb", kind: .model3D,
        fileExtension: "glb", byteCount: nil, modifiedAt: nil, errorMessage: nil)
    let workspace = EditorAnimationAssetWorkspace(document: asset, service: service)
    workspace.library = document
    return (root, workspace, document)
}
