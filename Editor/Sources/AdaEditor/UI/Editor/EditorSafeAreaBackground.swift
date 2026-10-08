@_spi(AdaEngine) import AdaEngine

struct EditorSafeAreaBackground: View {
    @Environment(\.theme) private var theme

    var body: some View {
        theme.editorColors.background
            .ignoresSafeArea()
    }
}
