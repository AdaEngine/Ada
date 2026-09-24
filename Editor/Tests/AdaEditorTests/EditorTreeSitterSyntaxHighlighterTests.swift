@_spi(AdaEngine) import AdaEngine
import Foundation
import Testing

@testable import AdaEditor

@Suite("EditorTreeSitterSyntaxHighlighter")
struct EditorTreeSitterSyntaxHighlighterTests {
    @Test("shader extensions open as editable source files")
    @MainActor
    func shaderFilesOpenInEditor() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shader-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let files = ["test.glsl", "test.WGSL", "test.comp", "test.geom", "test.tesc", "test.tese"]
        for name in files {
            try "// shader".write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        let editor = EditorViewModel(project: EditorProjectReference(name: "Shaders", path: root.path))
        for name in files {
            let expected: EditorSourceLanguage = name == "test.WGSL" ? .wgsl : .glsl
            #expect(EditorSourceLanguage.detect(fileName: name) == expected)
            let item = try #require(editor.projectSidebar.items.first { $0.title == name })
            editor.openProjectItem(item)
            guard case let .text(document)? = editor.workbench.activeDocument else {
                Issue.record("Shader should open in the code editor: \(name)")
                continue
            }
            #expect(document.language == expected)
            #expect(document.content == "// shader")
        }
    }

    @Test("highlights AdaScript syntax without treating it as Swift")
    func highlightsGravitySyntax() {
        var palette = EditorCodeColorPalette.dark
        palette.keyword = .green
        palette.string = .blue
        palette.type = .orange
        palette.comment = .yellow
        palette.number = .red
        palette.punctuation = .purple

        let tokens = EditorSyntaxHighlighter.tokens(
            for: """
                const speed = 12.5;
                var title = 'AdaScript';
                /* outer /* nested */ comment */
                @system(scheduler: "update")
                class MovementSystem { func update(context) {} }
                """,
            language: .ada,
            palette: palette
        )

        #expect(tokens.contains(EditorCodeToken(text: "const", color: .green)))
        #expect(tokens.contains(EditorCodeToken(text: "'AdaScript'", color: .blue)))
        #expect(tokens.contains(EditorCodeToken(text: "/* outer /* nested */ comment */", color: .yellow)))
        #expect(tokens.contains(EditorCodeToken(text: "MovementSystem", color: .orange)))
        #expect(tokens.contains(EditorCodeToken(text: "@system", color: .green)))
        #expect(tokens.contains(EditorCodeToken(text: "12.5", color: .red)))
        #expect(tokens.contains(EditorCodeToken(text: ";", color: .purple)))
    }

    @Test("AdaScript async and await are highlighted as keywords while editing")
    func highlightsAsyncKeywords() {
        let palette = EditorCodeColorPalette.dark
        let tokens = EditorSyntaxHighlighter.tokens(
            for: "async func run() { await work() }",
            language: .ada,
            palette: palette
        )

        #expect(tokens.contains(EditorCodeToken(text: "async", color: palette.keyword)))
        #expect(tokens.contains(EditorCodeToken(text: "await", color: palette.keyword)))
    }

    @Test("highlights Swift Package manifests with tree-sitter query captures")
    func highlightsSwiftPackageManifestsWithTreeSitterQueryCaptures() throws {
        var palette = EditorCodeColorPalette.dark
        palette.keyword = .green
        palette.string = .blue
        palette.type = .orange
        palette.comment = .yellow
        palette.number = .red
        palette.punctuation = .purple

        let tokens = EditorSyntaxHighlighter.tokens(
            for: """
                @MainActor
                let enabled = true
                let package = Package(name: "Ada", platforms: [.macOS(.v15)]) // manifest
                """,
            language: .packageManifest,
            palette: palette
        )

        #expect(tokens.contains(EditorCodeToken(text: "@", color: .green)))
        #expect(tokens.contains(EditorCodeToken(text: "MainActor", color: .green)))
        #expect(tokens.contains(EditorCodeToken(text: "let", color: .green)))
        #expect(tokens.contains(EditorCodeToken(text: "Package", color: .orange)))
        #expect(tokens.contains(EditorCodeToken(text: "Ada", color: .blue)))
        #expect(tokens.contains(EditorCodeToken(text: "true", color: .red)))
        #expect(tokens.contains(EditorCodeToken(text: "// manifest", color: .yellow)))
    }

    @Test("maps tree-sitter multiline Swift captures to per-line editor spans")
    func mapsTreeSitterMultilineSwiftCapturesToPerLineEditorSpans() throws {
        var palette = EditorCodeColorPalette.dark
        palette.string = .blue

        let spans = EditorSyntaxHighlighter.spans(
            for: "let text = \"\"\"\nAda\nEngine\n\"\"\"",
            language: .swift,
            palette: palette
        )

        #expect(spans.contains(TextEditorTokenSpan(line: 0, startColumn: 11, length: 3, color: .blue)))
        #expect(spans.contains(TextEditorTokenSpan(line: 1, startColumn: 0, length: 3, color: .blue)))
        #expect(spans.contains(TextEditorTokenSpan(line: 2, startColumn: 0, length: 6, color: .blue)))
        #expect(spans.contains(TextEditorTokenSpan(line: 3, startColumn: 0, length: 3, color: .blue)))
    }

    @Test("reuses syntax spans while unrelated editor state changes")
    func reusesSyntaxSpansForUnchangedSource() {
        let source = "let adaEditorSyntaxCacheRegressionValue = 42"
        let palette = EditorCodeColorPalette.dark

        #expect(!EditorSyntaxHighlighter.hasCachedSpans(for: source, language: .swift, palette: palette))

        let first = EditorSyntaxHighlighter.spans(for: source, language: .swift, palette: palette)
        #expect(EditorSyntaxHighlighter.hasCachedSpans(for: source, language: .swift, palette: palette))

        let second = EditorSyntaxHighlighter.spans(for: source, language: .swift, palette: palette)
        #expect(second == first)
    }
}
