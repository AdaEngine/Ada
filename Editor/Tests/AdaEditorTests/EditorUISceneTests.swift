@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorUISceneTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            let app = AppWorlds(main: World(name: "EditorUISceneTests"))
            RenderWorldPlugin().setup(in: app)
        }
    }

    @Test func realFileCanBeEditedSavedAndReopened() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Inventory.ui")
        let content = EditorNewFileKind.uiScene.initialContent(fileName: "Inventory.ui")
        try content.write(to: url, atomically: true, encoding: .utf8)
        let document = EditorTextDocument(
            id: "ui:Inventory.ui",
            title: "Inventory.ui",
            relativePath: "Inventory.ui",
            absolutePath: url.path,
            language: .plainText,
            content: content,
            lastSavedContent: content,
            errorMessage: nil
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.ui(document)], activeDocumentID: document.id)
        let model = workbench.uiSceneModel(for: document, resourceRoot: root)
        model.add("Grid")
        model.add("Text")
        model.updateSelected { $0.arguments["text"] = .init(value: .string("Inventory")) }
        #expect(workbench.activeDocument?.isDirty == true)
        #expect(workbench.saveActiveDocument())
        let saved = try UISceneDocument.decode(String(contentsOf: url, encoding: .utf8))
        #expect(saved.root.children.first?.type == "Grid")
        #expect(saved.root.children.first?.children.first?.arguments["text"]?.value == .string("Inventory"))
        let reopened = EditorUISceneModel(content: try String(contentsOf: url, encoding: .utf8), sourceURL: url, resourceRoot: root)
        #expect(reopened.document == model.document)
        #expect(reopened.error == nil)
    }

    @Test func paletteButtonCreatesRealAdaUIElement() throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        model.search = "Text"
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(x: 0, y: 0, width: 1440, height: 900)
        container.layoutSubviews()
        let target = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Text"))
        #expect(target.absoluteFrame.size.height > 0)
        #expect(container.bounds.contains(point: Point(target.absoluteFrame.midX, target.absoluteFrame.midY)))
        let hit = container.uiHitTest(at: Point(target.absoluteFrame.midX, target.absoluteFrame.midY))
        let layoutPath = try container.uiLayoutDiagnostics(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Text"), subtreeDepth: 0).parentPath
        #expect(
            hit?.path.contains { $0.accessibilityIdentifier == "AdaEditor.UIScene.Add.Text" } == true,
            "Palette target \(target.absoluteFrame), ancestors \(layoutPath.map { "\($0.nodeType.split(separator: "<").first ?? "") \($0.absoluteFrame)" })"
        )
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Text"))
        #expect(model.document.root.children.first?.type == "Text")
        #expect(model.preview != nil)
        #expect(model.error == nil)
    }

    @Test(arguments: [Size(width: 1440, height: 900), Size(width: 1100, height: 720)])
    func designerPanelsFillAvailableHeight(_ size: Size) throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(origin: .zero, size: size)
        container.layoutSubviews()
        let layout = EditorUIDesignerLayout(size: size)
        for panel in ["Library", "CanvasPanel", "Inspector"] {
            let node = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.\(panel)"))
            #expect(abs(node.absoluteFrame.height - layout.contentHeight) < 1)
            #expect(abs(node.absoluteFrame.minY - (layout.toolbarHeight + 1)) < 1)
            #expect(node.absoluteFrame.maxY <= size.height + 1)
        }
    }

    @Test func compactDesignerSwitchesPanelsWithoutLosingCanvasSpace() throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let container = UIContainerView(rootView: EditorUISceneEditor(model: model))
        container.frame = Rect(x: 0, y: 0, width: 480, height: 900)
        container.layoutSubviews()
        let pane = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.CanvasPanel"))
        #expect(pane.absoluteFrame.width == 480)
        #expect(pane.absoluteFrame.height == EditorUIDesignerLayout(size: Size(width: 480, height: 900)).contentHeight)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Pane.Library"))
        container.layoutSubviews()
        #expect(!container.uiFindNodes(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Text")).isEmpty)
    }

    @Test func zoomPreservesLogicalCanvasDimensions() throws {
        let preview = UIContainerView(rootView: Text("Canvas"))
        let host = EditorPreviewHostView()
        host.frame = Rect(x: 0, y: 0, width: 1600, height: 1200)
        host.configure(previewView: preview, zoom: 2, isInteractive: false, contentSize: Size(width: 800, height: 600))
        host.layoutSubviews()
        #expect(preview.frame.size == Size(width: 800, height: 600))
        #expect(host.previewPoint(from: Point(800, 600)) == Point(400, 300))
    }

    @Test func hierarchyEditsUndoAndRejectCyclesAndInvalidContent() throws {
        let model = EditorUISceneModel(content: try UISceneDocument().encodedYAML(), sourceURL: nil, resourceRoot: nil)
        let rootID = model.selectedID
        model.add("VStack")
        let stackID = model.selectedID
        model.add("Text")
        let textID = model.selectedID
        model.add("Text")
        #expect(model.selectedNode?.children.isEmpty == true)
        #expect(model.error != nil)
        model.move(stackID, into: textID)
        #expect(model.document.root.children.first?.id == stackID)
        model.move(textID, into: "missing")
        #expect(model.document.root.children.first?.children.first?.id == textID)
        model.selectedID = textID
        model.duplicateSelected()
        #expect(model.document.root.children.first?.children.count == 2)
        model.undo()
        #expect(model.document.root.children.first?.children.count == 1)
        model.redo()
        #expect(model.document.root.children.first?.children.count == 2)
        model.move(textID, into: rootID)
        #expect(model.document.root.children.last?.id == textID)
    }

    @Test func componentSourcePersistsAndLoadsInARealWorld() throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let ui = UISceneDocument(root: .init(type: "Text", arguments: ["text": .init(value: .string("HUD"))]))
        try ui.encodedYAML().write(to: root.appendingPathComponent("HUD.ui"), atomically: true, encoding: .utf8)
        var scene = EditorSceneModel.default(projectName: "UI Fixture")
        let entityID = scene.addEntity(name: "HUD", parentID: nil).id
        scene.addComponent(typeName: EditorBuiltInComponentType.uiComponent, to: entityID)
        scene.updateField(typeName: EditorBuiltInComponentType.uiComponent, field: .init(key: "path", label: "UI", kind: .string), value: "@res://HUD.ui", in: entityID)
        let yaml = try scene.encodedYAML()
        let world = World(name: "UISceneFixture")
        let result = EditorSceneFileLoader.load(content: yaml, into: world, loadsScriptableObjects: false, resourceRootURL: root)
        #expect(result.warnings.isEmpty)
        let entity = try #require(world.getEntities().first { $0.components.has(UIComponent.self) })
        let component = try #require(entity.components[UIComponent.self])
        #expect(component.source?.path == "@res://HUD.ui")
        #expect(try component.resolveView(runtime: world.getResource(UIComponentRuntimeResource.self)?.runtime) is UIContainerView<AnyView>)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AdaUI-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
