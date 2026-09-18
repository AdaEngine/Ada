@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("UI Designer workspace", .serialized)
@MainActor
struct EditorUIDesignerLayoutTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let worlds = AppWorlds(main: World(name: "DesignerLayoutTests"))
            RenderWorldPlugin().setup(in: worlds)
        }
    }

    @Test func compactWorkspaceKeepsCanvasAndSwitchesLibraryPanel() throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = makeContainer(model, size: Size(width: 768, height: 700))
        let artboard = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Artboard"))
        #expect(artboard.absoluteFrame.width > 300)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Pane.Library"))
        container.layoutIfNeeded()
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Text"))
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Text"))
        #expect(model.document.root.children.first?.type == "Text")
        #expect(model.selectedID == model.document.root.id)
        let textID = try #require(model.document.root.children.first?.id)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Library.Layers"))
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Node.\(textID)"))
        #expect(model.selectedID == textID)
        #expect(throws: (any Error).self) {
            try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Pane.Inspector"))
        }
    }

    @Test func inspectorPresentationShowsSelectedLayerProperties() throws {
        let document = UISceneDocument(root: .init(type: "Text", arguments: ["text": .init(value: .string("Hello"))]))
        let model = EditorUISceneModel(content: try document.encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model, presentation: .inspector))
        container.frame = Rect(x: 0, y: 0, width: 320, height: 700)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Inspector"))
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Parameter.text"))
    }

    @Test func contextualInspectorFillsTheRightPanelProposal() throws {
        let source = try UISceneDocument().encodedYAML()
        let document = EditorTextDocument(
            id: "ui:test",
            title: "test.ui",
            relativePath: "Assets/Scenes/test.ui",
            language: .yaml,
            content: source
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.ui(document)], activeDocumentID: document.id)
        let inspector = EditorInspectorSidebarViewModel()
        let container = UIContainerView(
            rootView: EditorContextualInspector(
                document: .ui(document),
                workbench: workbench,
                sceneInspectorViewModel: inspector,
                resourceRootURL: nil
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 360, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let contextualInspector = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ContextualInspector"))
        let uiInspector = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Inspector"))
        #expect(contextualInspector.absoluteFrame.width == 360)
        #expect(uiInspector.absoluteFrame.width == 360)
        #expect(uiInspector.absoluteFrame.minX == 0)
    }

    @Test func modifierLibraryIsExplicitAndAddsRealModifier() async throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = makeContainer(model, size: Size(width: 1440, height: 900))
        #expect(throws: (any Error).self) { try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifiers.Library")) }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifiers.Toggle"))
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        let dialog = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog"))
        #expect(dialog.absoluteFrame.width == 680)
        #expect(dialog.absoluteFrame.height == 680)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.background"))
        #expect(model.document.root.modifiers.first?.type == "background")
    }

    @Test func fittingScalesRenderingWithoutChangingLayoutSize() {
        let preview = UIView(frame: .zero)
        let host = EditorPreviewHostView(frame: Rect(x: 0, y: 0, width: 400, height: 300))
        host.bounds.size = Size(width: 400, height: 300)
        host.configure(previewView: preview, zoom: 0.5, isInteractive: false, contentSize: Size(width: 800, height: 600))
        host.layoutSubviews()
        #expect(preview.frame.size == Size(width: 800, height: 600))
        #expect(host.previewPoint(from: Point(100, 75)) == Point(200, 150))
    }

    @Test func emptyCanvasActionAndLayerSelectionRemainConnected() throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = makeContainer(model, size: Size(width: 1440, height: 900))
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Empty.AddText"))
        #expect(model.document.root.children.count == 1)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Library.Layers"))
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Node.\(model.document.root.id)"))
        #expect(model.selectedID == model.document.root.id)
    }

    @Test func fitSupportsLargeDocuments() {
        let layout = EditorUIDesignerLayout(size: Size(width: 1280, height: 790))
        let zoom = layout.fitZoom(width: 8192, height: 8192)
        #expect(zoom < 0.25)
        #expect(8192 * zoom <= layout.canvasWidth)
        #expect(8192 * zoom <= layout.contentHeight)
    }

    @Test func yamlSourceUsesPaletteAndRefreshesHighlightingAfterEdits() async throws {
        let document = UISceneDocument(root: .init(type: "Text", arguments: ["text": .init(value: .string("Hello # YAML"))]))
        let source = try document.encodedYAML() + "# YAML comment\n"
        let model = EditorUISceneModel(content: source, sourceURL: nil, resourceRoot: nil)
        model.showsSource = true
        var palette = EditorCodeColorPalette.dark
        palette.type = .orange
        palette.string = .green
        palette.comment = .blue
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model, colorPalette: palette))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let editor = try #require(sourceNode(in: container.viewTree.rootNode))
        #expect(editor.tokenSpans.contains { $0.color == palette.type })
        #expect(editor.tokenSpans.contains { $0.color == palette.string })
        #expect(editor.tokenSpans.contains { $0.color == palette.comment })
        #expect(editor.tokenSpans.contains { $0.color == palette.number })
        let updated = source.replacingOccurrences(of: "Hello # YAML", with: "Updated # YAML source")
        editor.textBinding.wrappedValue = updated
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(5))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(model.rawSource == updated)
        #expect(sourceNode(in: container.viewTree.rootNode) === editor)
        #expect(editor.text == updated)
        #expect(editor.tokenSpans == EditorSyntaxHighlighter.spans(for: updated, language: .yaml, palette: palette))
    }

    private func sourceNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode {
            return editor
        }
        return node.transientEnvironmentChildren.lazy.compactMap { sourceNode(in: $0) }.first
    }

    private func makeContainer(_ model: EditorUISceneModel, size: Size) -> UIContainerView<EditorUISceneEditor> {
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()
        return container
    }
}
