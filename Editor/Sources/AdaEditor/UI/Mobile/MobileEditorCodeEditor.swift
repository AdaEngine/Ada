#if os(iOS)
@_spi(AdaEngine) import AdaEngine

struct MobileEditorCodeEditor: View {
    let document: EditorTextDocument
    @State private var workbench: EditorWorkbenchViewModel

    init(document: EditorTextDocument) {
        self.document = document
        self._workbench = State(initialValue: EditorWorkbenchViewModel(
            openDocuments: [.text(document)],
            activeDocumentID: document.id
        ))
    }

    private var currentDocument: EditorTextDocument {
        workbench.textDocument(id: document.id) ?? document
    }

    var body: some View {
        EditorCodeFileView(
            document: currentDocument,
            text: workbench.textDocumentBinding(documentID: document.id),
            fontSize: workbench.codeFontSize,
            fontFamily: workbench.codeFontFamily,
            fontWeight: workbench.codeFontWeight,
            keywordFontWeight: workbench.keywordFontWeight,
            colorPalette: workbench.codeColorPalette,
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
        .onAppear {
            workbench.setDocumentEditedHandler { [weak workbench] documentID in
                _ = workbench?.saveTextDocument(id: documentID)
            }
        }
        .accessibilityIdentifier("AdaEditor.Mobile.Code.Editor")
    }
}
#endif
