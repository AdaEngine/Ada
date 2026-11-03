extension EditorWorkbenchViewModel {
    /// Selection belongs to the live text view. Preserve it for commands without
    /// publishing a document edit or rebuilding every consumer of openDocuments.
    func updateTextSelection(documentID: String, range: EditorSourceRange?, text: String?) {
        guard textDocument(id: documentID) != nil else { return }
        let selection = EditorTextSelection(range: range, text: text?.isEmpty == false ? text : nil)
        if textSelections[documentID] != selection {
            textSelections[documentID] = selection
        }
    }

    func applyingTextSelection(_ document: EditorWorkbenchDocument) -> EditorWorkbenchDocument {
        guard let selection = textSelections[document.id] else { return document }
        switch document {
        case var .text(text):
            text.selectionRange = selection.range
            text.selectedText = selection.text
            return .text(text)
        case var .ui(text):
            text.selectionRange = selection.range
            text.selectedText = selection.text
            return .ui(text)
        default:
            return document
        }
    }
}

struct EditorTextSelection: Equatable {
    var range: EditorSourceRange?
    var text: String?
}
