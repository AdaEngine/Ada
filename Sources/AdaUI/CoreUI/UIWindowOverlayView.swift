import AdaInput
import AdaUtils
import Math

/// A window layer composited after the window's cameras.
package final class UIWindowOverlayView: UIView {
    private let onClose: (@MainActor () -> Void)?

    package init(content: UIView, interactive: Bool = false, onClose: (@MainActor () -> Void)? = nil) {
        self.onClose = onClose
        super.init()
        isInteractionEnabled = interactive
        backgroundColor = .clear
        autoresizingRules = [.flexibleWidth, .flexibleHeight]
        content.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
    }

    package required init(frame: Rect) {
        self.onClose = nil
        super.init(frame: frame)
        isInteractionEnabled = false
        backgroundColor = .clear
    }

    override package func canRespondToAction(_: any InputEvent) -> Bool { isInteractionEnabled }

    override package func hitTest(_ point: Point, with event: any InputEvent) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    override package func layoutSubviews() {
        for subview in subviews {
            subview.safeAreaInsets = safeAreaInsets
        }
        super.layoutSubviews()
    }

    func closeWithWindow() {
        removeFromParentView()
        onClose?()
    }

    // The window compositor collects this layer separately from camera UI.
    override package func draw(with _: UIGraphicsContext) {}

    func drawOverlay(with context: UIGraphicsContext) {
        super.draw(with: context)
    }
}
