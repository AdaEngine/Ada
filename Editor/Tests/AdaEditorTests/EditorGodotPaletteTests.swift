@_spi(AdaEngine) import AdaEngine
import Testing

@testable import AdaEditor

@Suite("Godot syntax palette")
struct EditorGodotPaletteTests {
    @Test("AdaScript annotations, keywords, types, calls, strings and numbers use distinct reference colors")
    func highlightsAdaScript() {
        let palette = EditorCodeColorPalette.godot
        let tokens = EditorSyntaxHighlighter.tokens(
            for: "@export var speed: Vector3 = 16; camera.rotate(\"Zoom\"); // comment",
            language: .ada,
            palette: palette
        )
        #expect(tokens.contains { $0.text == "@export" && $0.color == palette.annotationColor })
        #expect(tokens.contains { $0.text == "var" && $0.color == palette.keyword })
        #expect(tokens.contains { $0.text == "Vector3" && $0.color == palette.type })
        #expect(tokens.contains { $0.text == "rotate" && $0.color == palette.functionColor })
        #expect(tokens.contains { $0.text == "16" && $0.color == palette.number })
        #expect(tokens.contains { $0.text == "\"Zoom\"" && $0.color == palette.string })
        #expect(tokens.contains { $0.text == "// comment" && $0.color == palette.comment })
        #expect(palette.annotationColor != palette.keyword)
        #expect(palette.functionColor != palette.type)
    }

    @Test("The preset applies through settings and is recognized when reopening settings")
    @MainActor
    func appliesPreset() {
        let editor = EditorViewModel(project: nil)
        let settings = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .general)
        settings.selectCodePalette(.godot)
        settings.applyGeneralSettings()
        #expect(editor.workbench.codeColorPalette == .godot)
        let reopened = EditorSettingsWindowViewModel(editorViewModel: editor, selectedSection: .general)
        #expect(reopened.codePalettePreset == .godot)
    }
}
