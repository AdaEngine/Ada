@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaUI
import Math
import Testing

@testable import AdaEditor

@MainActor @Suite(.serialized)
struct EditorAdaScriptHighlightTests {
    init() {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AdaScriptHighlightTests")))
        }
    }

    @Test("Async keywords have the keyword color with and without semantic tokens", arguments: [false, true])
    func asyncKeywordColors(semantic: Bool) throws {
        let source = "async func name() {\n    await work()\n}"
        let palette = EditorCodeColorPalette.dark
        let model = EditorWorkbenchViewModel()
        var document = EditorTextDocument(id: "async", title: "Async.ada", relativePath: "Async.ada", language: .ada, content: source, errorMessage: nil)
        if semantic {
            document.semanticTokens = EditorGravityLanguageService.semanticTokens(text: source)
        }
        model.open(.text(document))
        let container = UIContainerView(rootView: makeView(document: document, model: model, palette: palette).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))

        #expect(node.tokenSpans.contains { $0.line == 0 && $0.startColumn == 0 && $0.length == 5 && $0.color == palette.keyword })
        #expect(node.tokenSpans.contains { $0.line == 1 && $0.startColumn == 4 && $0.length == 5 && $0.color == palette.keyword })
    }

    @Test("AdaScript editor colors annotations and member access with and without semantic tokens", arguments: [false, true])
    func annotationAndMemberColors(semantic: Bool) throws {
        let source = Self.source
        let palette = EditorCodeColorPalette.dark
        let model = EditorWorkbenchViewModel()
        var document = EditorTextDocument(
            id: "ada",
            title: "Director.ada",
            relativePath: "Director.ada",
            language: .ada,
            content: source,
            errorMessage: nil
        )
        if semantic {
            document.semanticTokens = EditorGravityLanguageService.semanticTokens(text: source)
        }
        model.open(.text(document))
        let view = makeView(document: document, model: model, palette: palette)
        let container = UIContainerView(rootView: view.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        func color(line: Int, column: Int) -> Color? {
            node.tokenSpans.first {
                $0.line == line && $0.startColumn <= column && column < $0.startColumn + $0.length
            }?
            .color
        }
        #expect(color(line: 0, column: 0) == palette.keyword)
        #expect(color(line: 0, column: 1) == palette.keyword)
        #expect(color(line: 2, column: 4) == palette.keyword)
        #expect(color(line: 4, column: 21) == palette.type)  // outer
        #expect(color(line: 4, column: 34) == palette.type)  // moveX
        #expect(color(line: 5, column: 16) == palette.type)  // world
        #expect(color(line: 5, column: 22) == palette.type)  // commands
        #expect(color(line: 5, column: 31) == palette.type)  // spawn
        #expect(color(line: 6, column: 14) == palette.type)  // restart
        #expect(color(line: 7, column: 11) == palette.comment)
        #expect(color(line: 8, column: 21) == palette.string)
    }

    @Test("Godot palette distinguishes AdaScript properties from plain text", arguments: [false, true])
    func godotPropertyColors(semantic: Bool) throws {
        let source = "class Main { func update() { row.arenaPlayer.peer; } }"
        let palette = EditorCodeColorPalette.godot
        let model = EditorWorkbenchViewModel()
        var document = EditorTextDocument(id: "properties", title: "Main.ada", relativePath: "Main.ada", language: .ada, content: source, errorMessage: nil)
        if semantic {
            document.semanticTokens = EditorGravityLanguageService.semanticTokens(text: source)
        }
        model.open(.text(document))
        let container = UIContainerView(rootView: makeView(document: document, model: model, palette: palette).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        let column = try #require(source.range(of: "arenaPlayer")).lowerBound.utf16Offset(in: source)
        #expect(node.tokenSpans.contains { $0.line == 0 && $0.startColumn == column && $0.color == palette.memberColor })
        #expect(palette.memberColor != palette.plainText)
    }

    @Test("Editor preference reaches the text editor without disabling folding")
    func indentationPreference() throws {
        let suite = "AdaEditor.IndentationEditorTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorAppearanceSettings(defaults: defaults)
        let model = EditorWorkbenchViewModel()
        let document = EditorTextDocument(id: "indentation", title: "Main.ada", relativePath: "Main.ada", language: .ada, content: "class Main {\n    func update() {}\n}", errorMessage: nil)
        model.open(.text(document))
        var view = makeView(document: document, model: model, palette: .godot)
        view.appearanceSettings = settings
        let container = UIContainerView(rootView: view.theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 300)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        #expect(node.showsIndentationMarkers)
        #expect(node.foldingStyle == .braces)
        settings.showsIndentationMarkers = false
        container.layoutIfNeeded()
        #expect(!node.showsIndentationMarkers)
        #expect(node.foldingStyle == .braces)
    }

    @Test("Inserting an unfinished annotation invalidates old tokens and keeps subsequent lines colored", arguments: [EditorCodePalettePreset.adaDark, .godot])
    func editsInvalidateSemanticPositions(preset: EditorCodePalettePreset) throws {
        let original = "@system(scheduler: \"update\")\nclass MainSystem {\n    func update(context: AdaSystemContext) {\n        // gameplay\n    }\n}"
        let changed = original.replacingOccurrences(of: "    func", with: "    @export\n    func")
        let model = EditorWorkbenchViewModel()
        var document = EditorTextDocument(id: "edit", title: "Main.ada", relativePath: "Main.ada", language: .ada, content: original, errorMessage: nil)
        let oldTokens = EditorGravityLanguageService.semanticTokens(text: original)
        #expect(!oldTokens.isEmpty)
        document.semanticTokens = oldTokens
        model.open(.text(document))
        model.textDocumentBinding(documentID: document.id).wrappedValue = changed
        #expect(try #require(model.textDocument(id: document.id)).semanticTokens.isEmpty)
        model.applySemanticTokens(oldTokens, documentID: document.id, source: original)
        let updated = try #require(model.textDocument(id: document.id))
        #expect(updated.semanticTokens.isEmpty)
        let palette = preset.palette
        let container = UIContainerView(rootView: makeView(document: updated, model: model, palette: palette).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 900, height: 600)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        let node = try #require(editorNode(in: container.viewTree.rootNode))
        #expect(node.tokenSpans.contains { $0.line == 2 && $0.startColumn == 4 && $0.length == 7 && $0.color == palette.annotationColor })
        #expect(node.tokenSpans.contains { $0.line == 3 && $0.startColumn == 4 && $0.length == 4 && $0.color == palette.keyword })
        #expect(node.tokenSpans.contains { $0.line == 4 && $0.startColumn == 8 && $0.color == palette.comment })
        let newTokens = EditorGravityLanguageService.semanticTokens(text: changed)
        model.applySemanticTokens(newTokens, documentID: document.id, source: changed)
        #expect(try #require(model.textDocument(id: document.id)).semanticTokens == newTokens)
    }

    private func makeView(
        document: EditorTextDocument,
        model: EditorWorkbenchViewModel,
        palette: EditorCodeColorPalette
    ) -> EditorCodeFileView {
        EditorCodeFileView(
            document: document,
            text: model.textDocumentBinding(documentID: document.id),
            fontSize: 14,
            fontFamily: model.codeFontFamily,
            fontWeight: model.codeFontWeight,
            keywordFontWeight: model.keywordFontWeight,
            colorPalette: palette,
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

    private static let source = """
        @scriptable(id: "game.director")
        class Director {
            @res var progress: Progress;
            func update(context: AdaScriptableContext) {
                if (progress.outer) input.moveX = 0.0;
                context.world.commands.spawn([]);
                input.restart ();
                // @res progress.outer input.restart()
                var label = "@res progress.outer input.restart()";
            }
        }
        """

    private func editorNode(in node: ViewNode) -> TextEditorViewNode? {
        if let editor = node as? TextEditorViewNode {
            return editor
        }
        return node.transientEnvironmentChildren.lazy.compactMap { editorNode(in: $0) }.first
    }
}
