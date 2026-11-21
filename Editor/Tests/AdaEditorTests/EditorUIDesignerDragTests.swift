@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math
import Testing

@testable import AdaEditor

@Suite("UI Designer drag and drop", .serialized) @MainActor
struct EditorUIDesignerDragTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "DesignerDragTests")))
        }
    }

    @Test func atomicMovePreservesBindingsAndUndoAndRejectsCycles() throws {
        let text = UINodeDescription(type: "Text", arguments: ["text": .init(binding: "title")])
        let first = UINodeDescription(type: "VStack", children: [text])
        let second = UINodeDescription(type: "HStack")
        let document = UISceneDocument(root: .init(type: "ZStack", children: [first, second]), inputs: [.init("title", type: .string, defaultValue: .string("Hello"))])
        let model = try makeModel(document)
        var publications = 0
        model.onChange = { _ in publications += 1 }
        #expect(model.dropDesignerNode(text, at: .children(.init(parentID: second.id, index: 0))))
        #expect(model.node(second.id)?.children == [text])
        #expect(publications == 1 && model.selectedID == text.id)
        model.undo()
        #expect(model.document == document && !model.canUndo)
        model.redo()
        #expect(model.node(second.id)?.children == [text])
        #expect(!model.dropDesignerNode(try #require(model.node(second.id)), at: .children(.init(parentID: text.id, index: 0))))
        #expect(!model.dropDesignerNode(model.document.root, at: .free(parentID: nil, position: Point(0, 0))))
    }

    @Test func sameParentInsertionAndModifierSlotsAreStable() throws {
        let a = UINodeDescription(type: "Text"), b = UINodeDescription(type: "Text"), c = UINodeDescription(type: "Text")
        let overlay = UIModifierDescription(type: "overlay", children: [c])
        let model = try makeModel(.init(root: .init(type: "VStack", children: [a, b], modifiers: [overlay])))
        let root = model.document.root.id
        #expect(!model.dropDesignerNode(a, at: .children(.init(parentID: root, index: 1))))
        #expect(!model.canUndo)
        #expect(model.dropDesignerNode(a, at: .children(.init(parentID: root, index: 2))))
        #expect(model.document.root.children.map(\.id) == [b.id, a.id])
        #expect(model.dropDesignerNode(a, at: .children(.init(parentID: root, modifierID: overlay.id, index: 1))))
        #expect(model.document.root.modifiers[0].children.map(\.id) == [c.id, a.id])
        #expect(model.dropDesignerNode(c, at: .children(.init(parentID: root, index: 0))))
        #expect(model.document.root.modifiers[0].children.map(\.id) == [a.id])
        #expect(model.document.root.children.map(\.id) == [c.id, b.id])
    }

    @Test func freeDropWrapsRootOncePersistsAndReturnsToStack() throws {
        let child = UINodeDescription(type: "Text", arguments: ["text": .init(value: .string("Move"))])
        let document = UISceneDocument(root: .init(type: "VStack", children: [child]))
        let model = try makeModel(document)
        #expect(model.dropDesignerNode(child, at: .free(parentID: nil, position: Point(0.75, 0.9))))
        let freeID = model.document.root.id
        #expect(model.document.root.type == "FreeLayout")
        #expect(model.document.root.children[0].id == document.root.id)
        let moved = try #require(model.node(child.id))
        #expect(!model.dropDesignerNode(moved, at: .free(parentID: freeID, position: Point(0.75, 0.9))))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DesignerDrop-\(UUID().uuidString).ui")
        defer { try? FileManager.default.removeItem(at: url) }
        try model.rawSource.write(to: url, atomically: true, encoding: .utf8)
        let reopened = EditorUISceneModel(content: try String(contentsOf: url, encoding: .utf8), sourceURL: url, resourceRoot: url.deletingLastPathComponent())
        #expect(reopened.document == model.document && reopened.error == nil)
        #expect(model.dropDesignerNode(moved, at: .children(.init(parentID: document.root.id, index: 0))))
        #expect(model.node(child.id)?.modifiers.isEmpty == true)
        model.undo()
        #expect(model.node(child.id)?.modifiers.last?.type == "relativePosition")
        model.undo()
        #expect(model.document == document)
    }

    @Test func paletteDragUsesRealPointerCaptureAndPublishesOnlyOnRelease() async throws {
        let model = try makeModel(.init())
        let container = makeContainer(model)
        await refresh(container)
        let source = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Button"))
        let start = Point(source.absoluteFrame.midX, source.absoluteFrame.midY)
        let canvas = try #require(model.designerDrag.canvasFrame?())
        let end = Point(canvas.minX + canvas.width * 0.8, canvas.minY + canvas.height * 0.8)
        let original = model.document
        mouse(container, start, .began)
        mouse(container, end, .changed)
        #expect(model.designerDrag.isDragging && model.document == original && !model.canUndo)
        #expect(model.designerDrag.feedback?.valid == true)
        mouse(container, end, .ended)
        #expect(model.document.root.type == "FreeLayout")
        #expect(model.selectedNode?.type == "Button" && model.selectedNode?.modifiers.last?.type == "relativePosition")
        model.undo()
        #expect(model.document == original && !model.canUndo)
    }

    @Test func hierarchyAndCanvasDragsUseTheSameRuntimeGeometry() async throws {
        let previousLanguage = EditorLocalization.shared.preference
        defer { EditorLocalization.shared.preference = previousLanguage }
        EditorLocalization.shared.preference = .english
        let text = UINodeDescription(type: "Text", arguments: ["text": .init(value: .string("Drag me"))])
        let model = try makeModel(.init(root: .init(type: "VStack", children: [text])))
        let container = makeContainer(model)
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Library.Layers"))
        await refresh(container)
        let source = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Node.\(text.id)"))
        let canvas = try #require(model.designerDrag.canvasFrame?())
        let end = Point(canvas.minX + canvas.width * 0.8, canvas.minY + canvas.height * 0.8)
        mouse(container, Point(source.absoluteFrame.midX, source.absoluteFrame.midY), .began)
        mouse(container, end, .changed)
        mouse(container, end, .ended)
        #expect(model.document.root.type == "FreeLayout" && model.selectedID == text.id)
        await refresh(container)
        let next = Point(canvas.minX + canvas.width * 0.15, canvas.minY + canvas.height * 0.2)
        mouse(container, end, .began)
        mouse(container, next, .changed)
        mouse(container, next, .ended)
        #expect(try #require(model.node(text.id)?.modifiers.last?.arguments["x"]?.value?.number) < 0.3)
    }

    @Test func cancellationAndInteractLeaveDocumentUntouched() async throws {
        let model = try makeModel(.init())
        let container = makeContainer(model)
        await refresh(container)
        let source = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Button"))
        let point = Point(source.absoluteFrame.midX, source.absoluteFrame.midY)
        mouse(container, point, .began)
        mouse(container, Point(600, 600), .changed)
        mouse(container, Point(600, 600), .cancelled)
        #expect(!model.designerDrag.isDragging && !model.canUndo)
        model.isInteractive = true
        #expect(!model.dropDesignerNode(try #require(model.makeDesignerNode("Text")), at: .free(parentID: nil, position: Point(0.2, 0.2))))
        #expect(!model.canUndo)
    }

    @Test func compactTouchDragRetainsCaptureWhileRevealingCanvas() async throws {
        let model = try makeModel(.init())
        let container = makeContainer(model, size: Size(width: 768, height: 900))
        await refresh(container)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Pane.Library"))
        await refresh(container)
        _ = try container.uiScrollToNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Button"))
        await refresh(container)
        let source = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.UIScene.Add.Button"))
        let start = Point(source.absoluteFrame.midX, source.absoluteFrame.midY)
        let finger = RID()
        func touch(_ point: Point, _ phase: TouchEvent.Phase, _ time: Float) {
            container.onTouchesEvent([TouchEvent(window: .empty, location: point, phase: phase, time: time, contactID: finger)])
        }
        touch(start, .began, 0)
        container.update(0.31)
        await refresh(container)
        #expect(model.designerDrag.isDragging && !model.canUndo)
        let canvas = try #require(model.designerDrag.canvasFrame?())
        let end = Point(canvas.minX + canvas.width * 0.8, canvas.minY + canvas.height * 0.8)
        touch(end, .moved, 0.5)
        touch(end, .ended, 0.6)
        #expect(!model.designerDrag.isDragging)
        #expect(model.document.root.type == "FreeLayout" && model.selectedNode?.type == "Button")
    }

    private func makeModel(_ document: UISceneDocument) throws -> EditorUISceneModel {
        EditorUISceneModel(content: try document.encodedYAML(), sourceURL: nil, resourceRoot: nil)
    }

    private func makeContainer(_ model: EditorUISceneModel, size: Size = Size(width: 1440, height: 900)) -> UIContainerView<EditorUISceneEditor> {
        let view = UIContainerView(rootView: EditorUISceneEditor(model: model))
        view.frame = Rect(origin: .zero, size: size)
        view.bounds.size = size
        view.layoutIfNeeded()
        return view
    }

    private func mouse(_ view: UIView, _ point: Point, _ phase: MouseEvent.Phase) {
        view.onMouseEvent(MouseEvent(window: view.window?.id ?? .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0))
    }

    private func refresh(_ view: UIView) async {
        for _ in 0..<10 { await Task.yield(); view.update(1 / 60); view.layoutIfNeeded() }
    }
}
