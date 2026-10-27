@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Shader Graph workbench", .serialized) struct EditorShaderGraphWorkbenchTests {
    @Test func templatesCompileAndRouteAsGraphAssets() throws {
        for kind in [EditorNewFileKind.spriteShaderGraph, .pbrShaderGraph, .dissolveShaderGraph, .uvScrollShaderGraph] {
            let content = kind.initialContent(fileName: "Effect.shadergraph")
            let graph = try JSONDecoder().decode(ShaderGraph.self, from: Data(content.utf8))
            try graph.compileGLSL().validateGLSL()
            #expect(EditorViewModel.fileKind(for: URL(fileURLWithPath: "/Effect.shadergraph"), isDirectory: false) == .genericAsset)
            #expect(EditorViewModel.assetPreviewKind(for: .genericAsset, fileExtension: "shadergraph") == .shaderGraph)
        }
    }

    @Test func workbenchSharesHistorySavesAllAndProtectsAnExternallyChangedFile() throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = document(url)
        let workbench = EditorWorkbenchViewModel(openDocuments: [.asset(document)], activeDocumentID: document.id)
        let model = workbench.shaderGraphModel(for: document)
        #expect(workbench.shaderGraphModel(for: document) === model)
        model.moveNode("tint", to: .init(x: 85, y: 95))
        #expect(workbench.activeDocument?.isDirty == true)
        #expect(workbench.performDocumentHistory(redo: false))
        #expect(workbench.activeDocument?.isDirty == false)
        #expect(workbench.performDocumentHistory(redo: true))
        #expect(workbench.saveAllDocuments())
        #expect(!model.isDirty)
        #expect(EditorShaderGraphModel(url: url).graph?.layout["tint"] == .init(x: 85, y: 95))
        model.moveNode("tint", to: .init(x: 90, y: 100))
        let external = Data(EditorShaderGraphTemplates.initialContent(target: .sprite).utf8)
        try external.write(to: url)
        workbench.closeDocument(id: document.id)
        #expect(workbench.openDocuments.count == 1)
        #expect(model.isDirty)
        #expect(try Data(contentsOf: url) == external)
    }

    @Test func actualCanvasPointerEventsMoveAndConnectWithUndo() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorShaderGraphModel(url: url)
        model.editNode("output") { $0.inputs = [:] }
        let state = EditorNodeCanvasState()
        let interaction = model.canvasInteraction()
        let root = UIContainerView(rootView: EditorNodeCanvas(items: model.canvasItems, wires: model.canvasWires, selection: model.selection, state: state, interaction: interaction))
        root.frame = Rect(x: 40, y: 30, width: 1000, height: 600)
        root.bounds.size = root.frame.size
        root.layoutIfNeeded()
        let canvasFrame = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas")).absoluteFrame
        let geometry = EditorNodeCanvasGeometry(nodes: model.canvasItems, pan: state.pan, zoom: state.zoom)
        let source = try #require(geometry.port(.init(node: "tint", port: "value", isOutput: true)))
        let target = try #require(geometry.port(.init(node: "output", port: "baseColor", isOutput: false)))
        func point(_ value: Vector2) -> Point { .init(value.x + canvasFrame.minX, value.y + canvasFrame.minY) }
        for (value, phase) in [(source, MouseEvent.Phase.began), (target, .changed), (target, .ended)] { root.onMouseEvent(mouse(point(value), phase)) }
        #expect(model.graph?.nodes.last?.inputs["baseColor"] == .init("tint"))
        let start = geometry.screen([60, 195])
        for (value, phase) in [(start, MouseEvent.Phase.began), (start + Vector2(50, 20), .changed), (start + Vector2(50, 20), .ended)] { root.onMouseEvent(mouse(point(value), phase)) }
        #expect(model.graph?.layout["tint"] == .init(x: 80, y: 200))
        #expect(model.selection == ["tint"])
        model.undo()
        #expect(model.graph?.layout["tint"] == .init(x: 30, y: 180))
    }

    @Test func graphUsesTheContextualInspectorAndSearchDoesNotMoveTheCanvas() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let document = document(url)
        let workbench = EditorWorkbenchViewModel(openDocuments: [.asset(document)], activeDocumentID: document.id)
        let model = workbench.shaderGraphModel(for: document)
        let container = UIContainerView(rootView: HStack(spacing: 12) {
            EditorShaderGraphEditor(model: model).frame(width: 1050)
            EditorContextualInspector(
                document: .asset(document), workbench: workbench,
                sceneInspectorViewModel: EditorInspectorSidebarViewModel(), resourceRootURL: nil
            ).frame(width: 330)
        })
        container.frame = Rect(x: 0, y: 0, width: 1392, height: 800)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        for _ in 0..<10 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        let canvas = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas")).absoluteFrame
        let inspector = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.Inspector")).absoluteFrame
        #expect(canvas.minY == 44)
        #expect(canvas.width == 870)
        #expect(inspector.minX == 1062 && inspector.width == 330)
        let count = model.graph?.nodes.count ?? 0
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.AddNode"))
        #expect(model.graph?.nodes.count == count + 1)
        #expect(model.isDirty)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.OpenSearch"))
        for _ in 0..<10 { await Task.yield(); container.update(1 / 60); container.layoutIfNeeded() }
        let after = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas")).absoluteFrame
        let search = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.NodeSearch")).absoluteFrame
        #expect(after == canvas)
        #expect(search.width == 360 && search.height == 344)
    }

    @Test func graphFileHasItsOwnIconRegardlessOfFileClassification() {
        let item = EditorProjectSidebarViewModel.Item(
            id: "Effect.SHADERGRAPH", disclosure: "", icon: "", title: "Effect.SHADERGRAPH",
            relativePath: "Assets/Effect.SHADERGRAPH", level: 0, isActive: false, isFolder: false, kind: .genericAsset
        )
        #expect(EditorProjectFileAppearance.resolve(for: item) == .shaderGraph)
        #expect(EditorProjectFileAppearance.resolve(for: item).symbol != EditorProjectTreeIcon.description)
    }

    @Test func mountedEditorConnectsRenderedSocketsAndDeletesSelectedWireWithUndo() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let model = EditorShaderGraphModel(url: url)
        model.editNode("output") { $0.inputs["baseColor"] = nil }
        let root = UIContainerView(rootView: EditorShaderGraphEditor(model: model))
        root.frame = Rect(x: 0, y: 0, width: 1920, height: 900)
        root.bounds.size = root.frame.size
        func settle() async {
            for _ in 0..<12 { await Task.yield(); root.update(1 / 60); root.layoutIfNeeded() }
        }
        root.layoutIfNeeded()
        await settle()
        for zoom in [Float(0.5), 1.3, 2] {
            model.canvas.zoom(by: zoom / model.canvas.zoom, around: .zero)
            model.canvas.setPan([20, 45])
            await settle()
            let frame = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.NodeCanvas")).absoluteFrame
            let geometry = EditorNodeCanvasGeometry(nodes: model.canvasItems, pan: model.canvas.pan, zoom: model.canvas.zoom)
            let wire = EditorNodeCanvasWire(source: .init(node: "tint", port: "value", isOutput: true), target: .init(node: "output", port: "baseColor", isOutput: false), type: "color")
            let context = UIGraphicsContext()
            root.viewTree.rootNode.draw(with: context)
            var shapes: [String] = []
            let circles = context.getDrawCommands().compactMap { command -> Point? in
                guard case let .drawPath(path, transform, .fill) = command else { return nil }
                var points: [Vector2] = []
                var curves = 0
                path.forEach { element in
                    switch element {
                    case .move(let point): points.append(point)
                    case .curve(let point, _, _): points.append([point.x, point.y]); curves += 1
                    default: break
                    }
                }
                guard curves == 4, let left = points.map(\.x).min(), let right = points.map(\.x).max(),
                    let top = points.map(\.y).min(), let bottom = points.map(\.y).max() else { return nil }
                shapes.append("\(right - left)x\(bottom - top) at \(transform.origin)")
                guard abs(right - left - 10) < 0.1, abs(bottom - top - 10) < 0.1 else { return nil }
                let center = transform * Vector4((left + right) / 2, -(top + bottom) / 2, 0, 1)
                return Point(center.x, -center.y)
            }
            func renderedPort(_ endpoint: EditorNodeCanvasEndpoint) throws -> Point {
                let local = try #require(geometry.port(endpoint))
                let expected = Point(frame.minX + local.x, frame.minY + local.y)
                return try #require(
                    circles.first { abs($0.x - expected.x) < 0.2 && abs($0.y - expected.y) < 0.2 },
                    "Socket \(endpoint) at \(expected), zoom \(zoom); rendered centers: \(circles), shapes: \(shapes)"
                )
            }
            let source = try renderedPort(wire.source), target = try renderedPort(wire.target)
            let dragStart = zoom == 1.3 ? target : source
            let dragEnd = zoom == 1.3 ? source : target
            root.onMouseEvent(mouse(dragStart, .began))
            await settle()
            root.onMouseEvent(mouse(Point((source.x + target.x) / 2, source.y), .changed))
            await settle()
            root.onMouseEvent(mouse(dragEnd, .changed))
            await settle()
            root.onMouseEvent(mouse(dragEnd, .ended))
            await settle()
            #expect(model.canvasWires.contains(wire))
            let local = EditorNodeCanvasGeometry.wirePoint(from: try #require(geometry.port(wire.source)), to: try #require(geometry.port(wire.target)), t: 0.5)
            let point = Point(frame.minX + local.x, frame.minY + local.y)
            root.onMouseEvent(mouse(point, .began))
            root.onMouseEvent(mouse(point, .ended))
            await settle()
            #expect(model.selectedWire == wire)
            #expect(model.selection.isEmpty)
            let selectedContext = UIGraphicsContext()
            root.viewTree.rootNode.draw(with: selectedContext)
            #expect(selectedContext.getDrawCommands().contains { command in
                if case let .drawLine(_, _, width, _) = command { return width == 4 }
                return false
            })
            let nodeCount = model.graph?.nodes.count
            root.onKeyEvent(.init(window: .empty, keyCode: .delete, modifiers: [], status: .down, time: 0, isRepeated: false))
            await settle()
            #expect(!model.canvasWires.contains(wire))
            #expect(model.graph?.nodes.count == nodeCount)
            model.undo()
            #expect(model.canvasWires.contains(wire))
            #expect(model.selectedWire == wire)
            model.redo()
            #expect(!model.canvasWires.contains(wire))
            await settle()
        }
    }

    private func mouse(_ point: Point, _ phase: MouseEvent.Phase) -> MouseEvent { .init(window: .empty, button: .left, mousePosition: point, phase: phase, modifierKeys: [], time: 0) }

    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphWorkbench-\(UUID().uuidString).shadergraph")
        try Data(EditorShaderGraphTemplates.initialContent(target: .pbrSurface).utf8).write(to: url)
        return url
    }

    private func document(_ url: URL) -> EditorAssetDocument {
        .init(
            id: "asset:Effect.shadergraph",
            title: "Effect.shadergraph",
            relativePath: "Effect.shadergraph",
            absolutePath: url.path,
            assetReference: nil,
            kind: .shaderGraph,
            fileExtension: "shadergraph",
            byteCount: nil,
            modifiedAt: nil,
            errorMessage: nil
        )
    }
}
