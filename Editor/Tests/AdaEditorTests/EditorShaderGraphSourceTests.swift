@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Foundation
import Testing

@testable import AdaEditor

@MainActor @Suite("Shader Graph source editor", .serialized)
struct EditorShaderGraphSourceTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World()))
        }
    }

    @Test func sourceModeUsesTheSharedEditorAndRefreshesAfterEditsAndUndo() async throws {
        let savedFontSize = UserDefaults.standard.object(forKey: "AdaEditor.editor.fontSize")
        defer { UserDefaults.standard.set(savedFontSize, forKey: "AdaEditor.editor.fontSize") }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("GraphSource-\(UUID()).shadergraph")
        defer { try? FileManager.default.removeItem(at: url) }
        let data = Data(EditorShaderGraphTemplates.initialContent(target: .pbrSurface).utf8)
        try data.write(to: url)
        let model = EditorShaderGraphModel(url: url)
        let workbench = EditorWorkbenchViewModel(codeColorPalette: .dark, codeFontFamily: .system)
        // Registration restores saved preferences; choose the test size afterwards.
        workbench.codeFontSize = 17
        let root = UIContainerView(rootView: EditorShaderGraphEditor(model: model, workbench: workbench).theme(.adaEditor))
        root.frame = Rect(x: 0, y: 0, width: 1400, height: 700)
        root.bounds.size = root.frame.size
        func settle() async {
            for _ in 0..<15 { await Task.yield(); root.update(1 / 60); root.layoutIfNeeded() }
        }
        root.layoutIfNeeded()
        await settle()
        _ = try root.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.Source"))
        await settle()
        let frame = try root.uiNode(matching: .accessibilityIdentifier("AdaEditor.ShaderGraph.SourceEditor")).absoluteFrame
        #expect(frame == Rect(x: 180, y: 44, width: 1220, height: 656))
        let node = try #require(editorNode(in: root.viewTree.rootNode))
        let source = try #require(model.graph).compileGLSL().source
        #expect(node.text == source)
        #expect(node.showsLineNumbers && node.foldingStyle == .braces)
        #expect(node.resolvedFontPointSize() == 17)
        #expect(node.tokenSpans.contains { $0.color == workbench.codeColorPalette.keyword })
        #expect(node.tokenSpans.contains { $0.color == workbench.codeColorPalette.type })
        #expect(node.nearestScrollView() != nil)
        _ = try root.uiFocusNode(matching: .runtimeID(String(UInt(bitPattern: node.id), radix: 16)))
        #expect(root.uiPerformTextEditingCommand(.selectAll))
        #expect(node.selectedText() == source)
        root.onTextInputEvent(.init(window: .empty, text: "replace", action: .insert, time: 0))
        node.deleteBackward()
        node.insertNewlineWithIndentation()
        node.cutSelection()
        node.pasteText()
        node.undo()
        #expect(node.text == source && node.selectedText() == source)
        #expect(!model.isDirty && !model.canUndo)
        #expect(try Data(contentsOf: url) == data)

        model.editNode("output") { $0.inputs["baseColor"] = nil }
        await settle()
        #expect(editorNode(in: root.viewTree.rootNode) === node)
        #expect(node.text != source)
        #expect(node.text == (try model.graph?.compileGLSL().source))
        model.undo()
        await settle()
        #expect(node.text == source && !model.isDirty)
        workbench.codeFontSize = 19
        workbench.codeColorPalette = .godot
        await settle()
        #expect(node.resolvedFontPointSize() == 19)
        #expect(node.tokenSpans.contains { $0.color == EditorCodeColorPalette.godot.keyword })
    }

    private func editorNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode { return editor }
        return node.transientEnvironmentChildren.lazy.compactMap { editorNode(in: $0) }.first
    }
}
