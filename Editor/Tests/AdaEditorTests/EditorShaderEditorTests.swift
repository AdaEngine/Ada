@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorShaderEditorTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "ShaderEditorTests")))
        }
    }

    @Test("shader tokens use the editor palette and keyword font")
    func shaderPaletteAndFont() {
        let palette = EditorCodeColorPalette.dark
        let font = Font.system(size: 14, weight: .bold)
        for (source, language) in [("uniform vec4 color;", EditorSourceLanguage.glsl), ("var color: vec4f;", .wgsl)] {
            let spans = EditorSyntaxHighlighter.spans(for: source, language: language, palette: palette, keywordFont: font)
            #expect(spans.contains { $0.color == palette.keyword && $0.font == font })
            #expect(spans.contains { $0.color == palette.type })
            #expect(EditorSyntaxHighlighter.spans(for: source, language: language, palette: palette, keywordFont: font) == spans)
        }
    }

    @Test(arguments: [EditorSourceLanguage.glsl, .wgsl])
    func codeEditorDisplaysAndRefreshesShaderColors(_ language: EditorSourceLanguage) async throws {
        let source = language == .glsl ? "uniform vec4 color; // shader" : "var color: vec4f; // shader"
        let model = EditorWorkbenchViewModel()
        model.open(
            .text(
                EditorTextDocument(
                    id: "shader",
                    title: "test.\(language.rawValue)",
                    relativePath: "test.\(language.rawValue)",
                    language: language,
                    content: source,
                    errorMessage: nil
                )
            )
        )
        let container = UIContainerView(rootView: ShaderCodeTestView(model: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        #expect(node.tokenSpans.contains { $0.color == model.codeColorPalette.keyword })
        #expect(node.tokenSpans.contains { $0.color == model.codeColorPalette.type })
        #expect(node.tokenSpans.contains { $0.color == model.codeColorPalette.comment })

        // Editing through the real input binding must recolor the existing text editor node.
        node.textBinding.wrappedValue = "/* " + source
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(5))
            container.update(1.0 / 60.0)
            container.layoutIfNeeded()
        }
        #expect(editorNode(in: container.viewTree.rootNode) === node)
        #expect(node.text == "/* " + source)
        #expect(!node.tokenSpans.isEmpty)
        #expect(node.tokenSpans.allSatisfy { $0.color == model.codeColorPalette.comment })
    }

    private func editorNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode {
            return editor
        }
        return node.transientEnvironmentChildren.lazy.compactMap { editorNode(in: $0) }.first
    }
}

private struct ShaderCodeTestView: View {
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
