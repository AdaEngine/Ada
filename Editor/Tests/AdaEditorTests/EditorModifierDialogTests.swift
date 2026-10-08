@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorModifierDialogTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ModifierDialogTests")))
        }
    }

    @Test func searchAddDismissAndUndoUseRealDocument() async throws {
        let model = try makeModel()
        let container = makeContainer(model, size: Size(width: 1440, height: 900))
        try await open(container)
        _ = try container.uiFocusNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Search"))
        container.onTextInputEvent(TextInputEvent(window: RID(), text: "transparency", action: .insert, time: 0))
        await refresh(container)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.opacity")).isEmpty)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.padding")).isEmpty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.opacity"))
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog")).isEmpty)
        #expect(model.document.root.modifiers.first?.type == "opacity")
        #expect(try UISceneDocument.decode(model.rawSource).root.modifiers.first?.type == "opacity")
        model.undo()
        #expect(model.document.root.modifiers.isEmpty)
        model.redo()
        #expect(model.document.root.modifiers.count == 1)
        try await open(container)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.background")).isEmpty)
    }

    @Test func cancelCloseAndEscapeLeaveDocumentUnchanged() async throws {
        let model = try makeModel()
        let initial = model.document
        let container = makeContainer(model, size: Size(width: 1440, height: 900))
        for identifier in ["Cancel", "Close"] {
            try await open(container)
            _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.\(identifier)"))
            await refresh(container)
            #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog")).isEmpty)
        }
        try await open(container)
        container.onKeyEvent(KeyEvent(window: RID(), keyCode: .escape, modifiers: [], status: .down, time: 0, isRepeated: false))
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog")).isEmpty)
        #expect(model.document == initial)
        #expect(!model.canUndo)
    }

    @Test(arguments: [Size(width: 480, height: 700), Size(width: 768, height: 700), Size(width: 1440, height: 900)])
    func dialogFitsCompactAndDesktopEditors(_ size: Size) async throws {
        let container = makeContainer(try makeModel(), size: size)
        try await open(container)
        let frame = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog")).absoluteFrame
        #expect(frame.minX >= 0 && frame.maxX <= size.width)
        #expect(frame.minY >= 0 && frame.maxY <= size.height)
        #expect(frame.width > 400)
        #expect(frame.height > 600)
        let close = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Close"))
        #expect(frame.contains(point: Point(close.absoluteFrame.midX, close.absoluteFrame.midY)))
    }

    @Test func modalKeepsTheOriginalTargetAndBlocksBackgroundButtons() async throws {
        let model = try makeModel()
        model.add("Text")
        let childID = model.selectedID
        model.selectedID = model.document.root.id
        let container = makeContainer(model, size: Size(width: 1440, height: 900))
        try await open(container)
        model.selectedID = childID
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.background"))
        #expect(model.document.root.modifiers.first?.type == "background")
        #expect(model.document.root.children[0].modifiers.isEmpty)
        await refresh(container)
        try await open(container)
        let before = model.document
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifiers.Toggle"))
        #expect(model.document == before)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog")).isEmpty)
    }

    @Test func workbenchPresentsOverEntireWindowAndUpdatesItsDocument() async throws {
        let source = try UISceneDocument().encodedYAML()
        let document = EditorTextDocument(id: "UI", title: "UI", relativePath: "UI.ui", language: .plainText, content: source, errorMessage: nil)
        let workbench = EditorWorkbenchViewModel(openDocuments: [.ui(document)], activeDocumentID: document.id)
        let model = workbench.uiSceneModel(for: document, resourceRoot: nil)
        let container = UIContainerView(
            rootView: HStack(spacing: 0) {
                Color.blue.frame(width: 180)
                EditorUISceneEditor(model: model, presentation: .inspector)
            }
            .fullScreenCover(
                item: Binding(
                    get: { workbench.modifierPickerRequest },
                    set: { workbench.modifierPickerRequest = $0 }
                )
            ) { request in
                EditorAddModifierDialog(model: request.model, nodeID: request.nodeID)
            }
        )
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifiers.Toggle"))
        await refresh(container)
        #expect(workbench.modifierPickerRequest?.nodeID == model.document.root.id)
        let dialog = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog"))
        #expect(abs(dialog.absoluteFrame.midX - 720) < 1)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifier.Add.background"))
        await refresh(container)
        #expect(workbench.modifierPickerRequest == nil)
        #expect(workbench.activeDocument?.isDirty == true)
        #expect(model.document.root.modifiers.first?.type == "background")
    }

    @Test func catalogSearchFindsCategoriesAndCustomModifiers() {
        let padding = EditorModifierCatalogEntry(signature: .init(id: "padding", name: "padding"))
        #expect(padding.matches("layout space"))
        #expect(!padding.matches("navigation"))
        let custom = EditorModifierCatalogEntry(signature: .init(id: "MyGlow", name: "Glow", parameters: [.init("radius", type: .number)]))
        #expect(custom.matches("custom radius"))
    }

    private func makeModel() throws -> EditorUISceneModel {
        EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
    }

    private func makeContainer(_ model: EditorUISceneModel, size: Size) -> UIContainerView<EditorUISceneEditor> {
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model, presentation: .inspector))
        container.frame = Rect(origin: .zero, size: size)
        container.layoutSubviews()
        return container
    }

    private func open(_ container: UIContainerView<EditorUISceneEditor>) async throws {
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Modifiers.Toggle"))
        await refresh(container)
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.AddModifier.Dialog"))
    }

    private func refresh(_ container: UIView) async {
        for _ in 0..<10 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }
}
