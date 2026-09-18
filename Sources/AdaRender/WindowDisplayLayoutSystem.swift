import AdaECS
import Math

/// Conventional windows publish one region; embedding hosts explicitly supply their own layout.
@PlainSystem
struct WindowDisplayLayoutSystem {
    @ResMut<DisplayLayout> private var layout
    @Res private var embedded: EmbeddedDisplayLayout?
    @Res private var primaryWindow: PrimaryWindowId?

    init(world _: World) {}

    @MainActor func update(context _: UpdateContext) {
        guard
            embedded == nil, let primaryWindow,
            let window = unsafe RenderEngine.shared.getRenderWindow(for: primaryWindow.windowId)
        else {
            return
        }
        let next = DisplayLayout.standard(size: window.logicalSize.toSize())
        if layout != next {
            layout = next
        }
    }
}
