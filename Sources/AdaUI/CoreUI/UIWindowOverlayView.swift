import AdaInput
import AdaUtils
import Math

/// A passive window layer composited after the window's cameras.
package final class UIWindowOverlayView: UIView {
    private let onClose: (@MainActor () -> Void)?

    package init(content: UIView, onClose: (@MainActor () -> Void)? = nil) {
        self.onClose = onClose
        super.init()
        isInteractionEnabled = false
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

    override package func canRespondToAction(_: any InputEvent) -> Bool { false }

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
