@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorUILayerTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "UILayers")))
        }
    }

    @Test func canReselectStackAndAddMultipleChildrenWithoutReopeningEditor() async throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.add("VStack")
        let stackID = model.selectedID
        model.add("Button")
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        await refresh(container)
        for expectedCount in 2...3 {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Library.Layers"))
            await refresh(container)
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Node.\(stackID)"))
            await refresh(container)
            #expect(model.selectedID == stackID)
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Library.Components"))
            await refresh(container)
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Button"))
            await refresh(container)
            #expect(model.document.root.children.first?.children.count == expectedCount)
            #expect(model.error == nil)
        }
    }

    @Test func repeatedPaletteClicksAddSiblingsToSelectedStack() async throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.add("VStack")
        let stackID = model.selectedID
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        await refresh(container)
        for expectedCount in 1...3 {
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Button"))
            await refresh(container)
            #expect(model.selectedID == stackID)
            #expect(model.document.root.children.first?.children.count == expectedCount)
            #expect(model.document.root.children.first?.children.allSatisfy(\.children.isEmpty) == true)
            #expect(model.error == nil)
        }
    }

    @Test func mountedPreviewShowsEveryNewChild() async throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.add("VStack")
        let stackID = model.selectedID
        let preview = try #require(model.preview as? UIContainerView<UISceneView>)
        preview.frame = Rect(x: 0, y: 0, width: 800, height: 600)
        await refresh(preview)
        for _ in 0..<3 {
            model.selectedID = stackID
            model.add("Button")
            await refresh(preview)
            let ids = renderedIDs(preview.uiTreeRoots())
            for child in model.document.root.children[0].children {
                #expect(ids.contains(child.id))
            }
        }
    }

    @Test func collapseHidesDescendantsKeepsSelectionVisibleAndSurvivesRemount() async throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.add("VStack")
        let stackID = model.selectedID
        model.add("Button")
        let childID = model.selectedID
        let view = EditorUISceneEditor(model: model)
        let container = UIContainerView(rootView: view)
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Library.Layers"))
        await refresh(container)
        let before = model.rawSource
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Layer.Collapse.\(stackID)"))
        await refresh(container)
        #expect(model.selectedID == stackID)
        #expect(model.rawSource == before)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Node.\(childID)")).isEmpty)
        #expect(EditorUISceneEditor(model: model).rows.map(\.node.id) == [model.document.root.id, stackID])
        #expect(view.layerCount == 3)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Layer.Collapse.\(stackID)"))
        await refresh(container)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Node.\(childID)")).isEmpty)
    }

    @Test func collapseIncludesModifierChildrenAndAddingExpandsParent() throws {
        let child = UINodeDescription(type: "Text")
        let root = UINodeDescription(type: "VStack", modifiers: [.init(type: "overlay", children: [child])])
        let model = EditorUISceneModel(content: try UISceneDocument(root: root).encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.selectedID = child.id
        model.toggleLayerCollapsed(root.id)
        #expect(EditorUISceneEditor(model: model).rows.count == 1)
        #expect(model.selectedID == root.id)
        model.add("Text")
        #expect(!model.collapsedLayerIDs.contains(root.id))
        #expect(EditorUISceneEditor(model: model).rows.count == 3)
    }

    private func renderedIDs(_ nodes: [UINodeSnapshot]) -> Set<String> {
        Set(nodes.compactMap(\.sceneNodeID)).union(nodes.flatMap { renderedIDs($0.children) })
    }

    private func refresh(_ container: UIView) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }
}
