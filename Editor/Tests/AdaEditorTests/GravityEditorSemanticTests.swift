import GravityLanguageCore
import Testing

@testable import AdaEditor

@Suite("AdaScript editor semantic integration")
struct GravityEditorSemanticTests {
    @Test("Editor code action safely changes an invalid component class to a struct")
    func componentQuickFix() throws {
        let source = "@component class Health {}"
        let fixes = EditorGravityLanguageService.quickFixes(
            text: source,
            position: EditorSourceLocation(line: 0, character: 3)
        )
        let fix = try #require(fixes.first)
        #expect(fixes.count == 1)
        #expect(fix.title == "Change to struct")
        #expect(EditorViewModel.applyingSourceQuickFix(fix, to: source) == "@component struct Health {}")
        #expect(EditorViewModel.applyingSourceQuickFix(fix, to: "@component struct Health {}") == nil)
    }

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
