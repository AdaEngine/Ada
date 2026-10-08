@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorPropertyHistoryTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "PropertyHistory")))
        }
    }

    @Test func catalogPreservesEditorMetadataAndLegacyParameters() throws {
        let legacy = Data(#"{"name":"title","type":"string"}"#.utf8)
        #expect(try JSONDecoder().decode(UIParameter.self, from: legacy).editor == nil)
        let catalog = UICatalog.standard
        for signature in catalog.viewSignatures + catalog.modifierSignatures {
            for parameter in signature.parameters where parameter.editor != nil {
                let roundTrip = try JSONDecoder().decode(UIParameter.self, from: JSONEncoder().encode(parameter))
                #expect(roundTrip == parameter)
            }
        }
        #expect(catalog.views["Rectangle"]?.signature.parameters.first?.editor == .color)
        #expect(catalog.views["VStack"]?.signature.parameters.last?.editor == .enumeration(["leading", "center", "trailing"]))
        #expect(catalog.views["HStack"]?.signature.parameters.last?.editor == .enumeration(["top", "center", "bottom"]))
        #expect(catalog.modifiers["aspectRatio"]?.signature.parameters.last?.editor == .enumeration(["fit", "fill"]))
        #expect(catalog.modifiers["foregroundColor"]?.signature.parameters.first?.editor == .color)
    }

    @Test func dropdownEditsActualDocumentAndUndoRestoresValue() throws {
        var menu: ContextMenuPresentation?
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let document = UISceneDocument(root: .init(type: "VStack"))
        let model = EditorUISceneModel(content: try document.encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        container.layoutSubviews()
        let picker = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        #expect(picker.absoluteFrame.height == 30)
        #expect(menu?.items.map(\.title) == ["leading", "center", "trailing"])
        #expect(menu?.items.filter(\.isSelected).map(\.title) == ["center"])
        #expect(menu?.location == Point(picker.absoluteFrame.minX, picker.absoluteFrame.maxY))
        let selectTrailing = try #require(menu?.items.first { $0.title == "trailing" }?.action)
        selectTrailing()
        container.layoutSubviews()
        #expect(model.document.root.arguments["alignment"]?.value == .string("trailing"))
        #expect(model.error == nil)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.Enum.Option.trailing")).isEmpty)
        #expect(try UISceneDocument.decode(model.rawSource).root.arguments["alignment"]?.value == .string("trailing"))
        model.undo()
        #expect(model.document == document)
        model.redo()
        #expect(model.document.root.arguments["alignment"]?.value == .string("trailing"))
    }

    @Test func colorControlPreservesAlphaAndBindingMode() async throws {
        let value = EditorInspectorColorValue(red: 1, green: 0.5, blue: 0.25, alpha: 0.5)
        let parsed = try #require(EditorUIColorField.color(value.hexString))
        #expect(abs(parsed.alpha - 0.5) < 0.003)
        #expect(EditorUIColorField.color("red") == .red)
        #expect(EditorUIColorField.color("clear") == .clear)
        #expect(EditorUIColorField.color("invalid") == nil)
        let model = EditorUISceneModel(content: try UISceneDocument(root: .init(type: "Rectangle")).encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.edit { $0.inputs.append(.init("color", type: .string, defaultValue: .string("white"))) }
        model.updateSelected { $0.arguments["color"] = .init(value: .string(value.hexString)) }
        #expect(model.error == nil)
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        container.layoutSubviews()
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.ColorPicker")).isEmpty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Binding.color"))
        #expect(model.document.root.arguments["color"]?.binding == "color")
        for _ in 0..<10 {
            try await Task.sleep(for: .milliseconds(1))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.ColorPicker")).isEmpty)
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Parameter.color")).isEmpty)
        model.undo()
        #expect(model.document.root.arguments["color"]?.value == .string(value.hexString))
    }

    @Test func sceneHistoryTracksEditsAcrossSaveAndIgnoresSelection() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("History-\(UUID().uuidString).ascn")
        defer { try? FileManager.default.removeItem(at: url) }
        let document = try sceneDocument(id: "scene", url: url)
        try document.content.write(to: url, atomically: true, encoding: .utf8)
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        let original = try #require(document.sceneModel)
        workbench.addEntity(to: document.id)
        let edited = try #require(workbench.activeSceneDocument?.sceneModel)
        workbench.selectSceneEntity(documentID: document.id, entityID: original.rootEntityID)
        #expect(workbench.sceneUndoHistory[document.id]?.count == 1)
        #expect(workbench.saveActiveDocument())
        let saved = try String(contentsOf: url, encoding: .utf8)
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.activeSceneDocument?.sceneModel?.entities == original.entities)
        #expect(workbench.activeSceneDocument?.isDirty == true)
        #expect(workbench.activeSceneDocument?.lastSavedContent == saved)
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(workbench.activeSceneDocument?.sceneModel?.entities == edited.entities)
        #expect(workbench.activeSceneDocument?.isDirty == false)
        #expect(workbench.performDocumentHistory(redo: false))
        workbench.addEntity(to: document.id)
        #expect(!workbench.performDocumentHistory(redo: true))
    }

    @Test func shortcutsDispatchUndoAndBothRedoCombinations() throws {
        let document = try sceneDocument(id: "scene")
        let uiDocument = EditorTextDocument(
            id: "ui",
            title: "UI",
            relativePath: "UI.ui",
            language: .plainText,
            content: try UISceneDocument().encodedYAML(),
            errorMessage: nil
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document), .ui(uiDocument)], activeDocumentID: document.id)
        let ui = workbench.uiSceneModel(for: uiDocument, resourceRoot: nil)
        let container = UIContainerView(
            rootView: Color.clear.keyboardShortcuts(
                EditorHistoryShortcuts.actions {
                    workbench.performDocumentHistory(redo: $0 == .redo)
                }
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 100, height: 100)
        container.layoutSubviews()
        let count = document.sceneModel?.entities.count ?? 0
        workbench.addEntity(to: document.id)
        send(.command, to: container)
        #expect(workbench.activeSceneDocument?.sceneModel?.entities.count == count)
        send([.command, .alt], to: container)
        #expect(workbench.activeSceneDocument?.sceneModel?.entities.count == count + 1)
        workbench.activeDocumentID = uiDocument.id
        ui.add("Text")
        send(.command, to: container)
        #expect(ui.document.root.children.isEmpty)
        #expect(ui.selectedID == ui.document.root.id)
        send([.command, .shift], to: container)
        #expect(ui.document.root.children.count == 1)
        ui.reload(content: ui.rawSource)
        send(.command, to: container)
        #expect(ui.document.root.children.isEmpty)
        #expect(workbench.sceneDocument(id: document.id)?.sceneModel?.entities.count == count + 1)
    }

    @Test func sceneEnumDropdownWritesComponentAndCanBeUndone() throws {
        var menu: ContextMenuPresentation?
        let previousPresenter = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previousPresenter }
        let document = try sceneDocument(id: "scene")
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        workbench.selectSceneEntity(documentID: document.id, entityID: document.sceneModel?.rootEntityID)
        let type = EditorBuiltInComponentType.visibility
        workbench.addComponent(typeName: type, toSelectedEntityIn: document.id)
        let field = try #require(EditorComponentRegistry.descriptor(named: type)?.fields.first)
        guard case let .enumeration(cases) = field.kind else {
            Issue.record("Expected a reflected enum field")
            return
        }
        let before = try #require(workbench.activeSceneDocument?.content)
        let container = UIContainerView(
            rootView: EditorEnumField(
                cases: cases,
                selection: Binding(
                    get: { "visible" },
                    set: { workbench.updateComponentField(typeName: type, field: field, value: $0, inSelectedEntityOf: document.id) }
                )
            )
        )
        container.frame = Rect(x: 0, y: 0, width: 300, height: 220)
        container.layoutSubviews()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Enum.Toggle"))
        container.layoutSubviews()
        let selectHidden = try #require(menu?.items.first { $0.title == "hidden" }?.action)
        selectHidden()
        let after = try #require(workbench.activeSceneDocument?.content)
        #expect(after != before)
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.activeSceneDocument?.content == before)
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(workbench.activeSceneDocument?.content == after)
    }

    @Test func sceneHistoryDoesNotEditReadOnlyDocumentsOrOtherTabs() throws {
        let first = try sceneDocument(id: "first")
        var second = try sceneDocument(id: "second")
        second.isReadOnly = true
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(first), .scene(second)], activeDocumentID: first.id)
        workbench.addEntity(to: first.id)
        workbench.activeDocumentID = second.id
        #expect(!workbench.performDocumentHistory(redo: false))
        workbench.addEntity(to: second.id)
        #expect(workbench.sceneDocument(id: second.id)?.content == second.content)
        #expect(workbench.sceneUndoHistory[second.id] == nil)
        workbench.activeDocumentID = first.id
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.sceneDocument(id: first.id)?.content == first.content)
        #expect(workbench.activeSceneDocument?.isDirty == false)
    }

    private func send(_ modifiers: KeyModifier, to container: UIView) {
        container.onKeyEvent(KeyEvent(window: RID(), keyCode: .z, modifiers: modifiers, status: .down, time: 0, isRepeated: false))
    }

    private func sceneDocument(id: String, url: URL? = nil) throws -> EditorSceneDocument {
        let model = EditorSceneModel.default(projectName: "History")
        let content = try model.encodedYAML()
        return EditorSceneDocument(
            id: id,
            title: id,
            relativePath: "\(id).ascn",
            absolutePath: url?.path,
            content: content,
            lastSavedContent: content,
            sceneModel: model,
            errorMessage: nil,
            isDirty: false,
            statusMessage: nil,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
    }
}
