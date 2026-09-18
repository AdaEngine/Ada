@_spi(AdaEngine) import AdaEngine
import Math
import Testing

@testable import AdaEditor
@testable import AdaUI

@MainActor
@Suite(.serialized)
struct EditorInspectorRefreshTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "InspectorRefreshTests")))
        }
    }

    @Test(
        "field edits preserve component nodes, focus, and scroll position",
        arguments: [
            (EditorBuiltInComponentType.transform, "position", "10, 20, 30"),
            (EditorBuiltInComponentType.sprite, "tintColor", "0.5, 0.4, 0.8, 1"),
            (EditorBuiltInComponentType.sprite, "flipX", "true"),
            (EditorBuiltInComponentType.sprite, "size", "64, 48"),
            (EditorBuiltInComponentType.visibility, "value", "hidden"),
        ]
    )
    func editingPreservesComponentNodes(typeName: String, fieldKey: String, value: String) async throws {
        var scene = EditorSceneModel.default(projectName: "Inspector")
        let entity = scene.addEntity(preset: .sprite)
        let viewport = EditorSceneViewportModel()
        let inspector = EditorInspectorSidebarViewModel()
        viewport.configure(
            sceneContent: try scene.encodedYAML(),
            onSelectionChanged: { [weak inspector] in inspector?.selectEntity($0) },
            onDocumentContentChanged: { _ in }
        )
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.ToggleComponent.\(EditorBuiltInComponentType.transform)")
        _ = try container.uiScrollToNode(matching: selector)
        let initialNodes = componentHeaders(in: container.uiTreeRoots())
        let textField = try #require(
            flatten(container.uiTreeRoots())
                .first {
                    $0.nodeType.contains("TextFieldViewNode") && $0.canBecomeFocused
                }
        )
        _ = try container.uiFocusNode(matching: .runtimeID(textField.runtimeId))
        let field = try #require(
            inspector.selectedEntity?.components
                .first { $0.typeName == typeName }?
                .fields.first { $0.field.key == fieldKey }
        )
        inspector.updateComponentField = { typeName, field, value in
            scene.updateField(typeName: typeName, field: field, value: value, in: entity.id)
            do {
                viewport.configure(
                    sceneContent: try scene.encodedYAML(),
                    onSelectionChanged: { [weak inspector] in inspector?.selectEntity($0) },
                    onDocumentContentChanged: { _ in }
                )
            } catch {
                Issue.record(error)
            }
        }
        inspector.componentFieldBinding(typeName: typeName, field: field.field).wrappedValue = value
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(1))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
            let updatedNodes = componentHeaders(in: container.uiTreeRoots())
            #expect(updatedNodes.map(\.runtimeId) == initialNodes.map(\.runtimeId))
            #expect(updatedNodes.map(\.absoluteFrame) == initialNodes.map(\.absoluteFrame))
            #expect(try container.uiNode(matching: .runtimeID(textField.runtimeId)).isFocused)
        }
        #expect(inspector.selectedEntity?.editorID == entity.id)
        #expect(inspector.componentFieldBinding(typeName: typeName, field: field.field).wrappedValue == value)
        let persisted = try EditorSceneModel.decode(from: scene.encodedYAML())
        let payload = try #require(persisted.entities.first { $0.id == entity.id }?.components[typeName])
        #expect(field.field.displayValue(in: payload) == value)
    }

    @Test("debounced drag refresh preserves Inspector nodes, focus, and scroll")
    func draggingPreservesInspectorNodes() async throws {
        var scene = EditorSceneModel.default(projectName: "Inspector drag")
        _ = scene.addEntity(preset: .sprite)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let inspector = EditorInspectorSidebarViewModel()
        var selectionUpdates = 0
        viewport.configure(
            sceneContent: try scene.encodedYAML(),
            onSelectionChanged: {
                inspector.selectEntity($0)
                selectionUpdates += 1
            },
            onDocumentContentChanged: { _ in },
            onTransformChanged: { inspector.updateLiveTransform(editorID: $0, payload: $1) }
        )
        viewport.setViewportSize(Size(width: 800, height: 600))
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Inspector.ToggleComponent.\(EditorBuiltInComponentType.transform)"))
        let initialNodes = componentHeaders(in: container.uiTreeRoots())
        let textField = try #require(
            flatten(container.uiTreeRoots())
                .first {
                    $0.nodeType.contains("TextFieldViewNode") && $0.canBecomeFocused
                }
        )
        _ = try container.uiFocusNode(matching: .runtimeID(textField.runtimeId))
        let initialFields = inspector.transformFields
        let fieldNodes = textFields(in: container.viewTree.rootNode)
        let initialTexts = fieldNodes.map(\.text)
        let origin = try #require(viewport.transformGizmo()).screenOrigin
        #expect(viewport.beginTransformDragIfNeeded(at: origin, button: .left))
        let wasCounting = UILayoutDebugCounters.isEnabled
        UILayoutDebugCounters.isEnabled = true
        UILayoutDebugCounters.reset()
        #expect(viewport.updateTransformDrag(to: origin + Vector2(40, 0)))
        #expect(inspector.transformFields == initialFields)
        container.update(1.0 / 60.0)
        #expect(UILayoutDebugCounters.snapshot.contentInvalidations == 0)
        UILayoutDebugCounters.isEnabled = wasCounting
        let positionNode = try #require(container.viewTree.rootNode.findNodyByAccessibilityIdentifier("AdaEditor.Inspector.Axis.AdaTransform.Transform.position.X"))
        let positionField = try #require(textFields(in: positionNode).first)
        #expect(positionField.text == "40")
        #expect(selectionUpdates == 1)
        for _ in 0..<150 where selectionUpdates == 1 {
            try await Task.sleep(for: .milliseconds(10))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(selectionUpdates == 2)
        #expect(inspector.transformFields != initialFields)
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(1))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        let updatedNodes = componentHeaders(in: container.uiTreeRoots())
        #expect(updatedNodes.map(\.runtimeId) == initialNodes.map(\.runtimeId))
        #expect(updatedNodes.map(\.absoluteFrame) == initialNodes.map(\.absoluteFrame))
        #expect(try container.uiNode(matching: .runtimeID(textField.runtimeId)).isFocused)
        #expect(fieldNodes.map(\.text) != initialTexts)
        viewport.endTransformDrag(cancelled: true)
        #expect(inspector.transformFields == initialFields)
        container.update(1.0 / 60.0)
        #expect(positionField.text == "0")
    }

    @Test("Flip toggles update the saved value and move the existing thumb both ways", arguments: ["flipX", "flipY"])
    func flipThumbFollowsValue(fieldKey: String) async throws {
        var scene = EditorSceneModel.default(projectName: "Flip")
        let entity = scene.addEntity(preset: .sprite)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let inspector = EditorInspectorSidebarViewModel()
        viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
        inspector.updateComponentField = { type, field, value in
            scene.updateField(typeName: type, field: field, value: value, in: entity.id)
        }
        let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
        container.frame = Rect(x: 0, y: 0, width: 360, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Bool.AdaSprite.Sprite.\(fieldKey)")
        _ = try container.uiScrollToNode(matching: selector)
        let initialThumb = try #require(flatten([container.uiNode(matching: selector)]).first { $0.accessibilityIdentifier == "AdaEditor.Inspector.ToggleThumb" })
        for isOn in [true, false, true, false] {
            _ = try container.uiTapNode(matching: selector)
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(1))
                container.update(1.0 / 60.0)
                container.layoutIfNeeded()
            }
            let thumb = try #require(flatten([container.uiNode(matching: selector)]).first { $0.accessibilityIdentifier == "AdaEditor.Inspector.ToggleThumb" })
            #expect(thumb.runtimeId == initialThumb.runtimeId)
            #expect(abs(thumb.absoluteFrame.minX - initialThumb.absoluteFrame.minX - (isOn ? 14 : 0)) < 0.1)
            let savedScene = try EditorSceneModel.decode(from: scene.encodedYAML())
            let payload = try #require(savedScene.entities.first { $0.id == entity.id }?.components[EditorBuiltInComponentType.sprite])
            #expect(payload[fieldKey] == .bool(isOn))
        }
    }

    @Test("editing one live axis preserves the latest values of the other axes")
    func editingLiveAxisPreservesOtherAxes() throws {
        var scene = EditorSceneModel.default(projectName: "Live axes")
        let entity = scene.addEntity(preset: .sprite)
        let inspector = EditorInspectorSidebarViewModel()
        let viewport = EditorSceneViewportModel()
        viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
        let field = try #require(inspector.transformFields.first { $0.field.key == "position" })
        var editedValue: String?
        inspector.updateComponentField = { _, _, value in editedValue = value }
        inspector.updateLiveTransform(editorID: entity.id, payload: ["position": .array([.double(40), .double(50), .double(60)])])
        let x = inspector.transformVectorAxisBinding(field: field, axisIndex: 0)
        #expect(x.wrappedValue == "40")
        x.wrappedValue = "41"
        #expect(editedValue == "41, 50, 60")
        x.wrappedValue = "-"
        #expect(x.wrappedValue == "-")
        #expect(editedValue == "41, 50, 60")
    }

    private func componentHeaders(in nodes: [UINodeSnapshot]) -> [UINodeSnapshot] {
        flatten(nodes)
            .filter {
                $0.accessibilityIdentifier?.hasPrefix("AdaEditor.Inspector.ToggleComponent.") == true
            }
    }

    private func textFields(in node: ViewNode) -> [TextFieldViewNode] {
        if let field = node as? TextFieldViewNode {
            return [field]
        }
        return node.transientEnvironmentChildren.flatMap { textFields(in: $0) }
    }

    private func flatten(_ nodes: [UINodeSnapshot]) -> [UINodeSnapshot] {
        nodes.flatMap { [$0] + flatten($0.children) }
    }
}
