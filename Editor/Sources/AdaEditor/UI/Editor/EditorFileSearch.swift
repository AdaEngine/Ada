@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorFileSearchState: Equatable, Sendable {
    var isPresented = false
    var query = ""
    var selectedIndex = 0
}

enum EditorFileSearch {
    static func matches(in text: String, query: String) -> [EditorSourceRange] {
        guard !query.isEmpty else {
            return []
        }

        var matches: [EditorSourceRange] = []
        var searchRange = text.startIndex..<text.endIndex
        while let range = text.range(
            of: query,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        ) {
            matches.append(
                EditorSourceRange(
                    start: sourceLocation(at: range.lowerBound, in: text),
                    end: sourceLocation(at: range.upperBound, in: text)
                )
            )
            guard range.upperBound < text.endIndex else {
                break
            }
            searchRange = range.upperBound..<text.endIndex
        }
        return matches
    }

    private static func sourceLocation(at index: String.Index, in text: String) -> EditorSourceLocation {
        let prefix = text[..<index]
        let lines = prefix.split(separator: "\n", omittingEmptySubsequences: false)
        return EditorSourceLocation(
            line: max(0, lines.count - 1),
            character: lines.last?.count ?? 0
        )
    }
}

extension EditorWorkbenchViewModel {
    @discardableResult
    func presentFileSearch() -> Bool {
        switch activeDocument {
        case let .text(document)?, let .ui(document)?:
            return presentFileSearch(in: document)
        default:
            return false
        }
    }

    private func presentFileSearch(in document: EditorTextDocument) -> Bool {
        updateTextDocument(id: document.id) { updatedDocument in
            updatedDocument.fileSearch.isPresented = true
            if updatedDocument.fileSearch.query.isEmpty,
                let selectedText = updatedDocument.selectedText,
                !selectedText.isEmpty,
                !selectedText.contains("\n") {
                updatedDocument.fileSearch.query = selectedText
            }
            updateFileSearchSelection(in: &updatedDocument, selectedIndex: updatedDocument.fileSearch.selectedIndex)
        }
        return true
    }

    func updateFileSearchQuery(documentID: String, query: String) {
        updateTextDocument(id: documentID) { document in
            document.fileSearch.query = query
            updateFileSearchSelection(in: &document, selectedIndex: 0)
        }
    }

    func moveFileSearchSelection(documentID: String, delta: Int) {
        updateTextDocument(id: documentID) { document in
            let matches = EditorFileSearch.matches(in: document.content, query: document.fileSearch.query)
            guard !matches.isEmpty else {
                document.fileSearch.selectedIndex = 0
                document.focusedRange = nil
                return
            }
            let nextIndex = (document.fileSearch.selectedIndex + delta) % matches.count
            updateFileSearchSelection(
                in: &document,
                selectedIndex: nextIndex >= 0 ? nextIndex : nextIndex + matches.count
            )
        }
    }

    func dismissFileSearch(documentID: String) {
        updateTextDocument(id: documentID) { document in
            document.fileSearch.isPresented = false
            document.focusedRange = nil
        }
    }

    func refreshFileSearchSelection(documentID: String) {
        updateTextDocument(id: documentID) { document in
            guard document.fileSearch.isPresented else {
                return
            }
            updateFileSearchSelection(in: &document, selectedIndex: document.fileSearch.selectedIndex)
        }
    }

    private func updateFileSearchSelection(in document: inout EditorTextDocument, selectedIndex: Int) {
        let matches = EditorFileSearch.matches(in: document.content, query: document.fileSearch.query)
        guard !matches.isEmpty else {
            document.fileSearch.selectedIndex = 0
            document.focusedRange = nil
            return
        }
        let clampedIndex = min(max(0, selectedIndex), matches.count - 1)
        document.fileSearch.selectedIndex = clampedIndex
        document.focusedRange = matches[clampedIndex]
    }
}
