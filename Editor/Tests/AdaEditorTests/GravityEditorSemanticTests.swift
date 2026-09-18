import GravityLanguageCore
import Testing

@testable import AdaEditor

@Suite("AdaScript editor semantic integration")
struct GravityEditorSemanticTests {
    @Test("Editor maps AdaScript method tokens into renderable semantic tokens")
    func editorSemanticTokens() {
        let source = """
            @tool(id: "com.example.tool", permissions: [])
            class ExampleTool {
                func activate(editor) {
                    editor.addPanel(id: "panel");
                }
            }
            """

        let tokens = EditorGravityLanguageService.semanticTokens(text: source)

        #expect(tokens.contains { $0.type == "macro" && $0.line == 0 })
        #expect(tokens.contains { $0.type == "method" && $0.line == 2 && $0.startCharacter == 9 })
        #expect(tokens.contains { $0.type == "method" && $0.line == 3 })

        let toolCompletions = EditorGravityLanguageService.completions(
            text: "@to",
            position: EditorSourceLocation(line: 0, character: 3)
        )
        #expect(toolCompletions.contains { $0.label == "tool" && $0.kind == .annotation })
    }
}
