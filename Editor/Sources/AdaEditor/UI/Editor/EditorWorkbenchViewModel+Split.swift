import Foundation

enum EditorWorkbenchPane: String {
    case primary
    case secondary
}

extension EditorWorkbenchViewModel {
    var isSplit: Bool { !secondaryDocumentIDs.isEmpty }

    func pane(for documentID: String) -> EditorWorkbenchPane {
        secondaryDocumentIDs.contains(documentID) ? .secondary : .primary
    }

    func documents(in pane: EditorWorkbenchPane) -> [EditorWorkbenchDocument] {
        openDocuments.filter { self.pane(for: $0.id) == pane }
    }

    func selectedDocument(in pane: EditorWorkbenchPane) -> EditorWorkbenchDocument? {
        let documents = documents(in: pane)
        let selection = pane == .primary ? primarySelectedDocumentID : secondarySelectedDocumentID
        return documents.first { $0.id == activeDocumentID } ?? documents.first { $0.id == selection } ?? documents.first
    }

    func splitDocument(id: String) {
        guard openDocuments.contains(where: { $0.id == id }) else {
            return
        }
        if !isSplit {
            primarySelectedDocumentID = activeDocumentID
        }
        moveDocument(id: id, to: .secondary)
    }

    func focusPane(_ pane: EditorWorkbenchPane) {
        if let document = selectedDocument(in: pane) {
            guard document.id != activeDocumentID else {
                return
            }
            selectDocument(id: document.id)
        } else if focusedPane != pane {
            onActiveDocumentWillChange?()
            focusedPane = pane
            activeDocumentID = ""
            activeEditorTab = ""
            onActiveDocumentChanged?()
        }
    }

    func moveDocument(id: String, to pane: EditorWorkbenchPane) {
        guard openDocuments.contains(where: { $0.id == id }) else {
            return
        }
        if pane == .secondary {
            secondaryDocumentIDs.insert(id)
        } else {
            secondaryDocumentIDs.remove(id)
        }
        selectDocument(id: id)
    }

    func mergePanes() {
        secondaryDocumentIDs.removeAll()
        secondarySelectedDocumentID = nil
        primarySelectedDocumentID = activeDocumentID
        focusedPane = .primary
    }

    func reconcilePanes() {
        secondaryDocumentIDs.formIntersection(openDocuments.map(\.id))
        if secondaryDocumentIDs.isEmpty || secondaryDocumentIDs.count == openDocuments.count {
            mergePanes()
        }
    }
}
