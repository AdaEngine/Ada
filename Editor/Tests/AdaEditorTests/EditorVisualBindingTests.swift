@_spi(AdaEngine) import AdaEngine
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorVisualBindingTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "VisualBindings")))
        }
    }

    @Test func designerCreatesInputAndMappingWithCompoundUndoAndSave() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = fixture.model.document
        fixture.model.bindParameter(fixture.parameter, nodeID: original.root.id, modifierID: nil, to: fixture.mapping)
        #expect(fixture.model.error == nil)
        #expect(fixture.model.document.inputs.first?.name == "status")
        #expect(fixture.model.document.root.arguments["text"]?.binding == "status")
        #expect(fixture.model.bindingOwner?.mappings == ["status": fixture.mapping])
        #expect(fixture.workbench.performDocumentHistory(redo: false))
        #expect(fixture.model.document == original)
        #expect(fixture.model.bindingOwner?.mappings.isEmpty == true)
        #expect(fixture.workbench.performDocumentHistory(redo: true))
        #expect(fixture.model.bindingOwner?.mappings["status"] == fixture.mapping)
        #expect(fixture.workbench.saveActiveDocument())
        let savedUI = try UISceneDocument.decode(String(contentsOf: fixture.root.appendingPathComponent("HUD.ui"), encoding: .utf8))
        #expect(savedUI.root.arguments["text"]?.binding == "status")
        let savedScene = try String(contentsOf: fixture.root.appendingPathComponent("Main.ascn"), encoding: .utf8)
        let world = World(name: "Saved visual bindings")
        let loaded = EditorSceneFileLoader.load(content: savedScene, into: world, loadsScriptableObjects: false, resourceRootURL: fixture.root)
        #expect(loaded.warnings.isEmpty)
        let panel = try #require(world.getEntities().compactMap { $0.components[CompanionPanel.self] }.first)
        #expect(panel.ui.source?.scriptBindings == ["status": fixture.mapping])
    }

    @Test func sharedUIRequiresExplicitOwnerAndProtectsExistingInputs() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.workbench.updateSceneModelDocument(id: "scene", status: "Second owner") { scene in
            let entity = scene.addEntity(name: "Other HUD", parentID: nil)
            scene.addComponent(typeName: EditorBuiltInComponentType.companionPanel, to: entity.id)
            scene.entities[scene.entities.count - 1].components[EditorBuiltInComponentType.companionPanel]?["path"] = .string("@res://HUD.ui")
            scene.addScriptableObject(fixture.script, to: entity.id)
        }
        #expect(fixture.model.bindingOwners.count == 2)
        #expect(fixture.model.bindingOwner == nil)
        fixture.model.bindParameter(fixture.parameter, nodeID: fixture.model.selectedID, modifierID: nil, to: fixture.mapping)
        #expect(fixture.model.document.inputs.isEmpty)
        fixture.model.selectedBindingOwnerID = fixture.model.bindingOwners.first?.id
        fixture.model.edit { $0.inputs.append(.init("status", type: .number, defaultValue: .number(42))) }
        fixture.model.bindParameter(fixture.parameter, nodeID: fixture.model.selectedID, modifierID: nil, to: fixture.mapping)
        #expect(fixture.model.document.inputs.first?.type == .number)
        #expect(fixture.model.document.root.arguments["text"]?.binding == "status2")
        #expect(fixture.model.bindingOwners.last?.mappings.isEmpty == true)
        #expect(fixture.model.bindingOwner?.mappings["status2"] == fixture.mapping)
    }

    @Test func incompatibleFieldsAndConflictingUndoDoNotMutateDocuments() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let wrong = UIScriptFieldBinding(script: fixture.script.identifier, field: "speed")
        fixture.model.bindParameter(fixture.parameter, nodeID: fixture.model.selectedID, modifierID: nil, to: wrong)
        #expect(fixture.model.document.inputs.isEmpty)
        #expect(fixture.model.bindingOwner?.mappings.isEmpty == true)
        fixture.model.bindParameter(fixture.parameter, nodeID: fixture.model.selectedID, modifierID: nil, to: fixture.mapping)
        let bound = fixture.model.document
        let owner = try #require(fixture.model.bindingOwner)
        #expect(fixture.workbench.replaceUIBindings(owner: owner, expected: owner.mappings, replacement: ["external": wrong]))
        fixture.model.undo()
        #expect(fixture.model.document == bound)
        #expect(fixture.model.bindingOwner?.mappings == ["external": wrong])
        #expect(fixture.model.error?.contains("Cannot undo") == true)
    }

    @Test func propertyChainPickerCreatesRealBinding() async throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let container = UIContainerView(rootView: EditorUISceneEditor(model: fixture.model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.ScriptBinding.text"))
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ScriptFieldPicker.Toggle"))
        await refresh(container)
        #expect(container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.ScriptFieldPicker.Option.game.hud:speed")).isEmpty)
        for id in ["AdaEditor.ScriptFieldPicker.Toggle", "AdaEditor.ScriptFieldPicker.Unlink", "AdaEditor.ScriptFieldPicker.Option.game.hud:status"] {
            let node = try container.uiNode(matching: .accessibilityIdentifier(id))
            let hit = container.uiHitTest(at: Point(node.absoluteFrame.midX, node.absoluteFrame.midY))
            #expect(hit?.node.accessibilityIdentifier == id)
        }
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ScriptFieldPicker.Option.game.hud:status"))
        await refresh(container)
        #expect(fixture.model.document.root.arguments["text"]?.binding == "status")
        #expect(fixture.model.bindingOwner?.mappings["status"] == fixture.mapping)
    }

    @Test func modifierBindingsPreserveValuesAndRespectReadOnly() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        fixture.model.addModifier("opacity")
        let modifier = try #require(fixture.model.document.root.modifiers.first)
        let parameter = UIParameter("value", type: .number, defaultValue: .number(1))
        let mapping = UIScriptFieldBinding(script: fixture.script.identifier, field: "speed")
        fixture.model.isReadOnly = true
        fixture.model.bindParameter(parameter, nodeID: fixture.model.selectedID, modifierID: modifier.id, to: mapping)
        #expect(fixture.model.document.inputs.isEmpty)
        #expect(fixture.model.bindingOwner?.mappings.isEmpty == true)
        fixture.model.isReadOnly = false
        fixture.model.bindParameter(parameter, nodeID: fixture.model.selectedID, modifierID: modifier.id, to: mapping)
        #expect(fixture.model.document.inputs.first?.defaultValue == .number(1))
        #expect(fixture.model.document.root.modifiers.first?.arguments["value"]?.binding == "speed")
        #expect(fixture.model.document.root.arguments["text"]?.value == .string("Preview"))
        fixture.model.undo()
        #expect(fixture.model.document.root.modifiers.first == modifier)
        #expect(fixture.model.bindingOwner?.mappings.isEmpty == true)
    }

    private func refresh(_ container: UIView) async {
        for _ in 0..<12 {
            await Task.yield()
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
    }

    private struct Fixture {
        let root: URL
        let workbench: EditorWorkbenchViewModel
        let model: EditorUISceneModel
        let script: EditorScriptableObjectDescriptor
        var mapping: UIScriptFieldBinding { .init(script: script.identifier, field: "status") }
        var parameter: UIParameter { .init("text", type: .string, defaultValue: .string("Preview")) }
    }

    private func makeFixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("visual-bindings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try UISceneDocument(root: .init(type: "Text", arguments: ["text": .init(value: .string("Preview"))])).encodedYAML()
        let uiURL = root.appendingPathComponent("HUD.ui")
        try source.write(to: uiURL, atomically: true, encoding: .utf8)
        let script = EditorScriptableObjectDescriptor(
            fields: [.init(name: "status", defaultValue: .string("Ready"), kind: .string), .init(name: "speed", defaultValue: .double(1), kind: .float)],
            identifier: "game.hud",
            name: "HUD",
            requiredComponentTypeNames: [],
            sourcePath: "HUD.ada",
            version: 1
        )
        var scene = EditorSceneModel.default(projectName: "Bindings")
        let entity = scene.addEntity(name: "HUD", parentID: nil)
        scene.addComponent(typeName: EditorBuiltInComponentType.companionPanel, to: entity.id)
        scene.entities[scene.entities.count - 1].components[EditorBuiltInComponentType.companionPanel]?["path"] = .string("@res://HUD.ui")
        scene.addScriptableObject(script, to: entity.id)
        let content = try scene.encodedYAML()
        let sceneURL = root.appendingPathComponent("Main.ascn")
        try content.write(to: sceneURL, atomically: true, encoding: .utf8)
        let sceneDocument = EditorSceneDocument(
            id: "scene",
            title: "Main.ascn",
            relativePath: "Main.ascn",
            absolutePath: sceneURL.path,
            content: content,
            lastSavedContent: content,
            sceneModel: scene,
            errorMessage: nil,
            isDirty: false,
            loadSummary: EditorSceneFileLoader.summary(from: content)
        )
        let uiDocument = EditorTextDocument(
            id: "ui",
            title: "HUD.ui",
            relativePath: "HUD.ui",
            absolutePath: uiURL.path,
            language: .plainText,
            content: source,
            lastSavedContent: source,
            errorMessage: nil
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(sceneDocument), .ui(uiDocument)], activeDocumentID: "ui")
        let model = workbench.uiSceneModel(for: uiDocument, resourceRoot: root, bindingCatalog: [script])
        return Fixture(root: root, workbench: workbench, model: model, script: script)
    }
}
