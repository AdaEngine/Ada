@_spi(AdaEngine) import AdaEngine

/// Shared chat composer surface for the editor sidebar and mobile workspace.
struct EditorAgentComposerSurface<Content: View>: View {
    @Environment(\.theme) private var theme

    let cornerRadius: Float
    let horizontalInset: Float
    let topInset: Float
    let bottomInset: Float
    let usesGlass: Bool
    let content: Content

    init(
        cornerRadius: Float = 10,
        horizontalInset: Float = 8,
        topInset: Float = 8,
        bottomInset: Float = 8,
        usesGlass: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.horizontalInset = horizontalInset
        self.topInset = topInset
        self.bottomInset = bottomInset
        self.usesGlass = usesGlass
        self.content = content()
    }

    @ViewBuilder
    var body: some View {
        if usesGlass {
            surface
                .glassEffect(.regular.tint(Color.white.opacity(0.025)), in: .rect(cornerRadius: cornerRadius))
        } else {
            surface
        }
    }

    private var surface: some View {
        content
            .padding(.horizontal, horizontalInset)
            .padding(.top, topInset)
            .padding(.bottom, bottomInset)
            .background(RoundedRectangleShape(cornerRadius: cornerRadius).fill(theme.editorColors.surface))
            .overlay {
                RoundedRectangleShape(cornerRadius: cornerRadius)
                    .stroke(theme.editorColors.border, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}
