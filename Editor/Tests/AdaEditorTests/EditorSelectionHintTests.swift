@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite(.serialized)
struct EditorSelectionHintTests {
    @Test("Hint tracks selection direction, scroll, and visibility")
    func positioning() throws {
        prepareRenderer()
        let source = Array(repeating: String(repeating: "x", count: 150), count: 100).joined(separator: "\n")
        let hint = TextEditorSelectionHint(text: "Press CMD + L to chat", foreground: .white, background: .black, border: .gray)
        let container = UIContainerView(rootView: TextEditor(text: .constant(source), sourceInteraction: .init(selectionHint: hint)).font(.system(size: 14)))
        container.frame = Rect(x: 0, y: 0, width: 600, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        _ = try container.uiFocusNode(matching: .runtimeID(String(UInt(bitPattern: node.id), radix: 16)))
        node.selectionAnchor = 151 * 3
        node.selectionHead = 151 * 5 + 4
        let height = node.lineHeight(for: node.resolvedFontPointSize())
        let before = try #require(node.selectionHintFrame())
        #expect(abs(before.midY - (node.textContentRect().minY + 5.5 * height)) < 0.1)
        swap(&node.selectionAnchor, &node.selectionHead)
        let backwards = try #require(node.selectionHintFrame())
        #expect(abs(backwards.midY - (node.textContentRect().minY + 3.5 * height)) < 0.1)
        swap(&node.selectionAnchor, &node.selectionHead)
        let scroll = try #require(node.nearestScrollView())
        _ = scroll.scrollToVisibleRect(Rect(x: 650, y: 320, width: 10, height: 10), in: node)
        let scrolled = try #require(node.selectionHintFrame())
        #expect(scrolled.midY == before.midY)
        #expect(abs(scrolled.minX - scroll.contentOffset.x - before.minX) < 0.1)
        _ = scroll.scrollToVisibleRect(Rect(x: 0, y: 1500, width: 10, height: 10), in: node)
        #expect(node.selectionHintFrame() == nil)
        node.selectionAnchor = node.selectionHead
        #expect(node.selectionHintFrame() == nil)
    }

    @Test("Selection hint uses the same theme colors as completion")
    func colorsAndDrawing() throws {
        prepareRenderer()
        let model = EditorWorkbenchViewModel()
        model.open(
            .text(
                EditorTextDocument(
                    id: "hint",
                    title: "Hint.swift",
                    relativePath: "Hint.swift",
                    language: .swift,
                    content: "let value = 1\nlet other = 2",
                    errorMessage: nil
                )
            )
        )
        let container = UIContainerView(rootView: SelectionHintCodeView(model: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 700, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        let hint = try #require(node.sourceInteraction?.selectionHint)
        #expect(hint.background == Theme.adaEditor.editorColors.surface)
        #expect(hint.foreground == Theme.adaEditor.editorColors.text)
        #expect(hint.border == Theme.adaEditor.editorColors.border.opacity(0.65))
        _ = try container.uiFocusNode(matching: .runtimeID(String(UInt(bitPattern: node.id), radix: 16)))
        node.selectionAnchor = 0
        node.selectionHead = 3
        var context = UIGraphicsContext()
        node.drawSelectionHint(in: &context)
        #expect(
            context.getDrawCommands()
                .contains { command in
                    if case let .drawPath(_, _, .fill(color)) = command {
                        return color == hint.background
                    }
                    return false
                }
        )
    }

    private func editorNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode {
            return editor
        }
        return node.transientEnvironmentChildren.lazy.compactMap { editorNode(in: $0) }.first
    }

    private func prepareRenderer() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "SelectionHint")))
        }
    }
}

private struct SelectionHintCodeView: View {
    let model: EditorWorkbenchViewModel

    var body: some View {
        if case let .text(document)? = model.activeDocument {
            EditorCodeFileView(
                document: document,
                text: model.textDocumentBinding(documentID: document.id),
                fontSize: model.codeFontSize,
                fontFamily: model.codeFontFamily,
                fontWeight: model.codeFontWeight,
                keywordFontWeight: model.keywordFontWeight,
                colorPalette: model.codeColorPalette,
                onSourceHover: nil,
                onGoToDefinition: nil,
                onCompletionPosition: nil,
                onCompletionRequest: nil,
                onApplyCompletion: nil,
                onMoveCompletionSelection: nil,
                onAcceptCompletion: nil,
                onTextSelection: nil,
                onChatSelection: nil,
                sourceContextMenuItems: nil
            )
        }
    }
}
