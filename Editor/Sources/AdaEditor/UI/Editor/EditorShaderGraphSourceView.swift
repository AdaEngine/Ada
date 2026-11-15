@_spi(AdaEngine) import AdaEngine
import Foundation

/// Generated WGSL uses the same code surface and preferences as project source files.
struct EditorShaderGraphSourceView: View {
    let model: EditorShaderGraphModel
    var workbench: EditorWorkbenchViewModel?

    var body: some View {
        let document = sourceDocument
        EditorCodeFileView(
            document: document,
            text: .constant(document.content),
            fontSize: workbench?.codeFontSize ?? 14,
            fontFamily: workbench?.codeFontFamily ?? .firaCode,
            fontWeight: workbench?.codeFontWeight ?? .medium,
            keywordFontWeight: workbench?.keywordFontWeight ?? .bold,
            colorPalette: workbench?.codeColorPalette ?? .godot,
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("AdaEditor.ShaderGraph.SourceEditor")
    }

    private var sourceDocument: EditorTextDocument {
        let name = model.url?.deletingPathExtension().lastPathComponent ?? "ShaderGraph"
        var document = EditorTextDocument(
            id: "shadergraph-source:\(model.url?.path ?? name)",
            title: "\(name).generated.wgsl",
            relativePath: model.url?.lastPathComponent ?? "",
            language: .wgsl,
            content: "",
            isReadOnly: true,
            statusMessage: L10n.text("Generated · read only")
        )
        do {
            guard let graph = model.graph else { throw EditorShaderGraphFileError.unavailable }
            document.content = try graph.compileWGSL().source
        } catch {
            document.errorMessage = model.diagnosticMessage ?? String(describing: error)
        }
        return document
    }
}
