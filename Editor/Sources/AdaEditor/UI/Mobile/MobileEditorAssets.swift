#if os(iOS)
    @_spi(AdaEngine) import AdaEngine
    import Foundation

    @MainActor
    enum MobileEditorAssets {
        static let forestPreview: Image? = {
            guard let url = Bundle.editor.url(forResource: "ForestPreview", withExtension: "png", subdirectory: "Assets/Mobile") else {
                return nil
            }
            return try? Image(contentsOf: url)
        }()
    }
#endif
