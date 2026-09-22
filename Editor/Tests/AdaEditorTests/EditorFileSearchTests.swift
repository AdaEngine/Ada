import Testing

@testable import AdaEditor

@MainActor
struct EditorFileSearchTests {
    @Test func findsCaseInsensitiveMatchesAcrossLines() {
        let matches = EditorFileSearch.matches(
            in: "alpha beta\nBeta gamma\nbetAlpha",
            query: "beta"
        )

        #expect(matches.count == 3)
        #expect(matches[0] == EditorSourceRange(
            start: EditorSourceLocation(line: 0, character: 6),
            end: EditorSourceLocation(line: 0, character: 10)
        ))
        #expect(matches[1].start == EditorSourceLocation(line: 1, character: 0))
        #expect(matches[2].start == EditorSourceLocation(line: 2, character: 0))
    }

    @Test func workbenchPresentsNavigatesAndDismissesFileSearch() throws {
        let document = EditorTextDocument(
            id: "main",
            title: "main.ada",
            relativePath: "Sources/main.ada",
            language: .ada,
            content: "let value = 1\nprint(value)\nvalue = 2",
            errorMessage: nil
        )
        let workbench = EditorWorkbenchViewModel(
            openDocuments: [.text(document)],
            activeDocumentID: document.id
        )

        #expect(workbench.presentFileSearch())
        workbench.updateFileSearchQuery(documentID: document.id, query: "value")
        var updated = try #require(workbench.textDocument(id: document.id))
        #expect(updated.fileSearch.isPresented)
        #expect(updated.fileSearch.selectedIndex == 0)
        #expect(updated.focusedRange?.start == EditorSourceLocation(line: 0, character: 4))

        workbench.moveFileSearchSelection(documentID: document.id, delta: 1)
        updated = try #require(workbench.textDocument(id: document.id))
        #expect(updated.fileSearch.selectedIndex == 1)
        #expect(updated.focusedRange?.start == EditorSourceLocation(line: 1, character: 6))

        workbench.moveFileSearchSelection(documentID: document.id, delta: 1)
        workbench.moveFileSearchSelection(documentID: document.id, delta: 1)
        updated = try #require(workbench.textDocument(id: document.id))
        #expect(updated.fileSearch.selectedIndex == 0)

        workbench.dismissFileSearch(documentID: document.id)
        updated = try #require(workbench.textDocument(id: document.id))
        #expect(!updated.fileSearch.isPresented)
        #expect(updated.focusedRange == nil)
    }
}
