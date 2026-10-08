import Foundation
import Testing

@testable import AdaEditor

@Suite("Shader syntax lexer")
struct EditorShaderSyntaxHighlighterTests {
    @Test func glslDirectivesTypesAndEntryPoint() {
        let source = """
            #version 450 core
            #pragma stage : vert
            layout(location = 0) in vec3 a_Position;
            [[main]]
            void vertex_main() {
                gl_Position = vec4(a_Position, 1.0);
            }
            """
        check(
            source,
            language: .glsl,
            expected: [
                ("#version", .keyword), ("450", .number), ("#pragma", .keyword),
                ("layout", .keyword), ("in", .keyword), ("vec3", .type), ("[[main]]", .keyword),
                ("void", .type), ("vertex_main", .type), ("gl_Position", .type), ("vec4", .type), ("1.0", .number),
            ]
        )
    }

    @Test func wgslAttributesTemplatesAndNumbers() {
        let source = """
            @group(0) @binding(1) var<uniform> transform: mat4x4<f32>;
            @vertex fn main(@location(0) position: vec3f) -> @builtin(position) vec4f {
                let tiny = 1.2e-3f + .5h;
                let bits = 0xffu;
                let hexadecimal = 0x1.fp+2;
                return vec4f(position, 1.0);
            }
            """
        check(
            source,
            language: .wgsl,
            expected: [
                ("@group", .keyword), ("@binding", .keyword), ("var", .keyword), ("uniform", .keyword),
                ("mat4x4", .type), ("f32", .type), ("@vertex", .keyword), ("fn", .keyword),
                ("@location", .keyword), ("@builtin", .keyword), ("vec3f", .type), ("vec4f", .type),
                ("1.2e-3f", .number), (".5h", .number), ("0xffu", .number), ("0x1.fp+2", .number), ("return", .keyword),
            ]
        )
    }

    @Test func commentStateAndStringsProtectKeywords() {
        let wgsl = "/* outer\n/* inner */ fn hidden() {}\n*/ var visible = true; // @fragment"
        check(
            wgsl,
            language: .wgsl,
            expected: [
                ("/* outer", .comment), ("/* inner */ fn hidden() {}", .comment),
                ("*/", .comment), ("var", .keyword), ("true", .number), ("// @fragment", .comment),
            ]
        )
        let glsl = "/* outer /* inner */ uniform float visible;\n#include \"folder//shader.glsl\""
        check(
            glsl,
            language: .glsl,
            expected: [
                ("/* outer /* inner */", .comment), ("uniform", .keyword),
                ("#include", .keyword), ("\"folder//shader.glsl\"", .string),
            ]
        )
    }

    @Test func editingRecomputesCommentStateAndKeepsCharacterColumns() {
        let source = "// 😀 comment\n/* unterminated\nvec4 hidden;"
        let tokens = EditorShaderSyntaxHighlighter.tokens(for: source, language: .glsl)
        #expect(tokens.allSatisfy { $0.kind == .comment })
        let edited = "/* 😀 */ vec4 visible;"
        check(edited, language: .glsl, expected: [("/* 😀 */", .comment), ("vec4", .type)])
        let editedTokens = EditorShaderSyntaxHighlighter.tokens(for: edited, language: .glsl)
        #expect(editedTokens.first { $0.kind == .type }?.column == 8)
        #expect(EditorShaderSyntaxHighlighter.tokens(for: "", language: .wgsl).isEmpty)
    }

    @Test func adjacentOperatorsDoNotBecomePartOfNumbers() {
        check(
            "1.0+2.0-3u",
            language: .wgsl,
            expected: [
                ("1.0", .number), ("+", .punctuation), ("2.0", .number), ("-", .punctuation), ("3u", .number),
            ]
        )
    }

    private func check(
        _ source: String,
        language: EditorShaderSyntaxHighlighter.Language,
        expected: [(String, EditorShaderSyntaxHighlighter.Kind)]
    ) {
        let lines = source.components(separatedBy: .newlines).map(Array.init)
        let tokens = EditorShaderSyntaxHighlighter.tokens(for: source, language: language)
        for (text, kind) in expected {
            #expect(
                tokens.contains { token in
                    token.kind == kind && String(lines[token.line][token.column..<(token.column + token.length)]) == text
                },
                "Missing shader token: \(text)"
            )
        }
        for pair in zip(tokens, tokens.dropFirst()) where pair.0.line == pair.1.line {
            #expect(pair.0.column + pair.0.length <= pair.1.column)
        }
    }
}
