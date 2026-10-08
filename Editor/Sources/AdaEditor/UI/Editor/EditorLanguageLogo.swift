@_spi(AdaEngine) import AdaEngine
import Foundation

@MainActor
enum EditorLanguageLogo {
    private static let adaScript = loadImage(named: "adascript_logo")
    private static let swift = loadImage(named: "swift_logo")

    static func image(for language: EditorSourceLanguage) -> Image? {
        switch language {
        case .ada:
            return adaScript
        case .swift:
            return swift
        case .c, .cpp, .glsl, .wgsl, .json, .markdown, .metal, .packageManifest, .plainText, .yaml:
            return nil
        }
    }

    private static func loadImage(named name: String) -> Image? {
        guard let url = Bundle.editor.url(forResource: name, withExtension: "png", subdirectory: "Assets/Icons") else {
            return nil
        }
        return try? Image(contentsOf: url)
    }
}
