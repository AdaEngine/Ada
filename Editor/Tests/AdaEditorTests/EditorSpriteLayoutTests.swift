@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorSpriteLayoutTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SpriteLayoutInspector")))
        }
        EditorComponentRegistry.registerBuiltIns()
    }

    @Test("Inspector presets and mode menus edit the runtime layout through AdaUI events")
    func inspectorMenus() throws {
        var scene = EditorSceneModel.default(projectName: "Layout")
        let entity = scene.addEntity(preset: .empty)
        let type = EditorBuiltInComponentType.sprite
        scene.addComponent(typeName: type, to: entity.id)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let inspector = EditorInspectorSidebarViewModel()
        inspector.updateComponentField = { type, field, value in scene.updateField(typeName: type, field: field, value: value, in: entity.id) }
        var menu: ContextMenuPresentation?
        let previous = ContextMenuPresentationCenter.present
        ContextMenuPresentationCenter.present = { menu = $0 }
        defer { ContextMenuPresentationCenter.present = previous }
        for (key, value) in [("anchorPreset", "Top Right"), ("imageMode", "fit"), ("imageMode", "fill"), ("imageMode", "sliced"), ("imageMode", "tiled")] {
            _ = viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
            let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
            container.frame = Rect(x: 0, y: 0, width: 380, height: 1100)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            let selector = UINodeSelector.accessibilityIdentifier("AdaEditor.Inspector.Enum.\(type).\(key)")
            _ = try container.uiScrollToNode(matching: selector)
            _ = try container.uiTapNode(matching: selector)
            let action = try #require(menu?.items.first { $0.title == value }?.action)
            action()
            let payload = try #require(scene.entities.first { $0.id == entity.id }?.components[type])
            let decoded = try #require(EditorComponentRegistry.decode(typeName: type, payload: payload) as? Sprite)
            #expect(decoded.anchor == .topRight)
            if key == "imageMode" { #expect(EditorSpriteLayoutFields.fields.first { $0.key == key }?.displayValue(in: payload) == value) }
        }
    }

    @Test("Layout fields save, reopen, load in the scene world and support undo/redo")
    func sceneRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Layout.ascn")
        var scene = EditorSceneModel.default(projectName: "Layout")
        let entity = scene.addEntity(preset: .empty)
        let type = EditorBuiltInComponentType.sprite
        scene.addComponent(typeName: type, to: entity.id)
        let content = try scene.encodedYAML()
        try content.write(to: url, atomically: true, encoding: .utf8)
        let document = EditorSceneDocument(
            id: "Layout",
            title: "Layout",
            relativePath: "Layout.ascn",
            absolutePath: url.path,
            content: content,
            lastSavedContent: content,
            sceneModel: scene,
            isDirty: false,
            loadSummary: .init(entityCount: 0, warnings: [])
        )
        let workbench = EditorWorkbenchViewModel(openDocuments: [.scene(document)], activeDocumentID: document.id)
        let descriptor = try #require(EditorComponentRegistry.descriptor(named: type))
        for (key, value) in [
            ("size", "160, 80"), ("anchorPreset", "Bottom Left"), ("anchor", "0.25, -0.75"),
            ("imageMode", "sliced"), ("imageMode.sliced._0.top", "8"), ("imageMode.sliced._0.right", "12"),
        ] {
            let field = try #require(descriptor.fields.first { $0.key == key })
            workbench.updateComponentField(typeName: type, field: field, value: value, inSelectedEntityOf: document.id)
        }
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(workbench.saveActiveDocument())
        let reopened = try EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
        let world = World()
        let result = EditorSceneFileLoader.load(model: reopened, into: world, loadsScriptableObjects: false, resourceRootURL: root)
        #expect(result.warnings.isEmpty)
        let id = try #require(result.entitiesByEditorID[entity.id])
        let sprite = try #require(world.get(Sprite.self, from: id))
        #expect(sprite.anchor == SpriteAnchor(x: 0.25, y: -0.75))
        #expect(sprite.size == Size(width: 160, height: 80))
        #expect(sprite.imageMode == .sliced(SpriteSliceBorder(top: 8, right: 12)))
    }

    @Test("Custom anchors, fractional scale, tiled axes and borders accept real text and pointer input")
    func parameterControls() async throws {
        let type = EditorBuiltInComponentType.sprite
        var scene = EditorSceneModel.default(projectName: "Layout controls")
        let entity = scene.addEntity(preset: .empty)
        scene.addComponent(typeName: type, to: entity.id)
        let fields = EditorSpriteLayoutFields.fields
        let mode = try #require(fields.first { $0.key == "imageMode" })
        scene.updateField(typeName: type, field: mode, value: "tiled", in: entity.id)
        let viewport = EditorSceneViewportModel()
        defer { viewport.disconnect() }
        let inspector = EditorInspectorSidebarViewModel()
        inspector.updateComponentField = { type, field, value in scene.updateField(typeName: type, field: field, value: value, in: entity.id) }
        func container() throws -> UIContainerView<EditorInspectorSidebar> {
            _ = viewport.configure(sceneContent: try scene.encodedYAML(), onSelectionChanged: { inspector.selectEntity($0) }, onDocumentContentChanged: { _ in })
            let container = UIContainerView(rootView: EditorInspectorSidebar(viewModel: inspector))
            container.frame = Rect(x: 0, y: 0, width: 380, height: 1100)
            container.bounds.size = container.frame.size
            container.layoutIfNeeded()
            return container
        }
        func enter(_ text: String, id: String, in container: UIContainerView<EditorInspectorSidebar>) async throws {
            let selector = UINodeSelector.accessibilityIdentifier(id)
            _ = try container.uiScrollToNode(matching: selector)
            let rect = try container.uiNode(matching: selector).absoluteFrame
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(rect.maxX - 15, rect.midY), phase: .began, modifierKeys: [], time: 0))
            container.onMouseEvent(MouseEvent(window: RID(), button: .left, mousePosition: Point(rect.maxX - 15, rect.midY), phase: .ended, modifierKeys: [], time: 0.1))
            #expect(container.uiPerformTextEditingCommand(.selectAll))
            for character in text {
                container.onTextInputEvent(TextInputEvent(window: RID(), text: String(character), action: .insert, time: 0))
                for _ in 0..<3 { await Task.yield() }
                container.update(1.0 / 60)
                container.layoutIfNeeded()
            }
        }
        let tiled = try container()
        try await enter("0.25", id: "AdaEditor.Inspector.Axis.\(type).anchor.X", in: tiled)
        try await enter("0.5", id: "AdaEditor.Inspector.Value.\(type).imageMode.tiled.scale", in: tiled)
        _ = try tiled.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.Inspector.Bool.\(type).imageMode.tiled.tileX"))
        _ = try tiled.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Inspector.Bool.\(type).imageMode.tiled.tileX"))
        var payload = try #require(scene.entities.first { $0.id == entity.id }?.components[type])
        var sprite = try #require(EditorComponentRegistry.decode(typeName: type, payload: payload) as? Sprite)
        #expect(sprite.anchor.x == 0.25)
        #expect(sprite.imageMode == .tiled(tileX: false, tileY: true, scale: 0.5))
        scene.updateField(typeName: type, field: mode, value: "sliced", in: entity.id)
        let sliced = try container()
        try await enter("8.5", id: "AdaEditor.Inspector.Value.\(type).imageMode.sliced._0.top", in: sliced)
        payload = try #require(scene.entities.first { $0.id == entity.id }?.components[type])
        sprite = try #require(EditorComponentRegistry.decode(typeName: type, payload: payload) as? Sprite)
        #expect(sprite.imageMode == .sliced(SpriteSliceBorder(top: 8.5)))
    }

    @Test("Legacy scenes keep defaults and invalid layout input preserves saved values")
    func legacyAndInvalid() throws {
        let type = EditorBuiltInComponentType.sprite
        var payload: EditorComponentPayload = ["tintColor": .object(["red": .double(1), "green": .double(1), "blue": .double(1), "alpha": .double(1)])]
        let sprite = try #require(EditorComponentRegistry.decode(typeName: type, payload: payload) as? Sprite)
        #expect(sprite.anchor == .center && sprite.imageMode == .stretch)
        let nativePayload = try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(Sprite(size: Size(width: 160, height: 80))))
        #expect(EditorSpriteLayoutFields.sizeField.displayValue(in: nativePayload) == "160, 80")
        let fields = EditorSpriteLayoutFields.fields
        let mode = try #require(fields.first { $0.key == "imageMode" })
        mode.write("tiled", to: &payload)
        let snapshot = payload
        let scale = try #require(fields.first { $0.key == "imageMode.tiled.scale" })
        for invalid in ["0", "-1", "nan", "inf", "1e100"] { scale.write(invalid, to: &payload) }
        #expect(payload == snapshot)
        #expect(fields.filter { EditorSpriteLayoutFields.isVisible($0, in: payload) }.filter { $0.valuePath.count > 1 }.count == 3)
        mode.write("sliced", to: &payload)
        #expect(fields.filter { EditorSpriteLayoutFields.isVisible($0, in: payload) }.filter { $0.valuePath.count > 1 }.count == 4)
    }
}
