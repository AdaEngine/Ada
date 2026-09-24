import Math
import Testing

@testable import AdaEditor

@Suite("Editor code completion layout")
struct EditorCodeCompletionLayoutTests {
    @Test("Snippet markers become an editable selection, and Enter keeps the default name")
    @MainActor
    func snippetPlaceholderAcceptsDefault() throws {
        let item = EditorCompletionItem(
            label: "func",
            detail: nil,
            insertText: "func $name$() {\n    \n}",
            replacementRange: nil,
            sortText: nil,
            kind: .snippet
        )
        let document = EditorTextDocument(
            id: "main",
            title: "main.ada",
            relativePath: "main.ada",
            absolutePath: "/tmp/main.ada",
            language: .ada,
            content: "fu",
            completionItems: [item],
            completionPosition: EditorSourceLocation(line: 0, character: 2)
        )
        let viewModel = EditorViewModel(
            project: EditorProjectReference(name: "Game", path: "/tmp"),
            workbench: EditorWorkbenchViewModel(activeEditorTab: "main.ada", openDocuments: [.text(document)], activeDocumentID: document.id)
        )

        viewModel.applyCompletion(item, to: document)
        guard case let .text(inserted)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        let name = try #require(inserted.activeSnippetPlaceholder)
        #expect(inserted.content == "func name() {\n    \n}")
        #expect(name == EditorSourceRange(
            start: EditorSourceLocation(line: 0, character: 5),
            end: EditorSourceLocation(line: 0, character: 9)
        ))
        #expect(inserted.focusedRange == name)
        #expect(viewModel.acceptSnippetPlaceholder(in: inserted, selection: name))

        guard case let .text(accepted)? = viewModel.workbench.activeDocument else {
            Issue.record("Expected active text document")
            return
        }
        #expect(accepted.content == inserted.content)
        #expect(accepted.activeSnippetPlaceholder == nil)
        #expect(accepted.focusedRange == EditorSourceRange(start: name.end, end: name.end))
        #expect(!viewModel.acceptSnippetPlaceholder(in: accepted, selection: name))
    }

    @Test("Snippet placeholders keep their position after multiline indentation")
    @MainActor
    func indentedSnippetPlaceholder() throws {
        let item = EditorCompletionItem(
            label: "func",
            detail: nil,
            insertText: "func $name$() {\n    $body$\n}",
            replacementRange: nil,
            sortText: nil,
            kind: .snippet
        )
        let result = try #require(EditorViewModel.applyingCompletion(item, to: "class Main {\n    fu\n}", at: .init(line: 1, character: 6)))
        #expect(result.text == "class Main {\n    func name() {\n        body\n    }\n}")
        #expect(result.placeholder == EditorSourceRange(
            start: EditorSourceLocation(line: 1, character: 9),
            end: EditorSourceLocation(line: 1, character: 13)
        ))
    }

    @Test("Multiline AdaScript completion preserves the containing method indentation")
    @MainActor
    func indentsAsyncFunctionSnippet() throws {
        let source = "class Main {\n    as\n}"
        let item = EditorCompletionItem(
            label: "async func",
            detail: nil,
            insertText: "async func name() {\n    \n}",
            replacementRange: EditorSourceRange(
                start: EditorSourceLocation(line: 1, character: 4),
                end: EditorSourceLocation(line: 1, character: 6)
            ),
            sortText: nil,
            kind: .snippet
        )
        let result = try #require(EditorViewModel.applyingCompletion(item, to: source, at: EditorSourceLocation(line: 1, character: 6)))

        #expect(result.text == "class Main {\n    async func name() {\n        \n    }\n}")
        #expect(result.caret == EditorSourceLocation(line: 3, character: 5))
    }

    @Test("small iPad viewport keeps only complete completion rows")
    func smallViewportDoesNotClipCompletionRows() {
        let viewport = Size(width: 440, height: 120)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: viewport,
            caretRect: Rect(x: 128, y: 82, width: 1.5, height: 18),
            itemCount: 40
        )
        let contentHeight = frame.height - EditorCompletionPopupLayout.verticalPadding * 2

        #expect(frame.minY >= EditorCompletionPopupLayout.viewportInset)
        #expect(frame.maxY <= viewport.height - EditorCompletionPopupLayout.viewportInset)
        #expect(contentHeight.truncatingRemainder(dividingBy: EditorCompletionPopupLayout.rowHeight) == 0)
    }

    @Test("completion moves above a caret near the bottom edge")
    func completionUsesSpaceAboveBottomCaret() {
        let caretRect = Rect(x: 128, y: 104, width: 1.5, height: 18)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 440, height: 140),
            caretRect: caretRect,
            itemCount: 2
        )

        #expect(frame.maxY <= caretRect.minY)
    }

    @Test("completion tracks the visible caret after document scrolling")
    func completionTracksScrolledCaret() {
        let caretRect = Rect(x: 240, y: 74, width: 1.5, height: 18)
        let frame = EditorCompletionPopupLayout.frame(
            viewportSize: Size(width: 900, height: 700),
            caretRect: caretRect,
            itemCount: 3
        )

        #expect(frame.minX == caretRect.minX)
        #expect(frame.minY == caretRect.maxY)
    }
}
