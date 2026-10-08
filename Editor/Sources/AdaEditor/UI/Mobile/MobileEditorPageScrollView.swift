@_spi(AdaEngine) import AdaEngine

/// The mobile host already places the page inside the device safe area.
/// Inset the initial content for navigation chrome while letting it scroll underneath.
struct MobileEditorPageScrollView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        ScrollView(
            .vertical,
            showsIndicators: true,
            respectsSafeArea: false,
            extendsUnderNavigationBar: true
        ) {
            content
        }
        .accessibilityIdentifier("AdaEditor.Mobile.PageScroll")
    }
}
