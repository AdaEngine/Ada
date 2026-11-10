import AdaInput
import Math

/// A passive window layer composited after the window's cameras.
package final class UIWindowOverlayView: UIView {
    package init(content: UIView) {
        super.init()
        isInteractionEnabled = false
        autoresizingRules = [.flexibleWidth, .flexibleHeight]
        content.autoresizingRules = [.flexibleWidth, .flexibleHeight]
        addSubview(content)
    }

    package required init(frame: Rect) {
        super.init(frame: frame)
        isInteractionEnabled = false
    }

    override package func canRespondToAction(_: any InputEvent) -> Bool { false }

    // The window compositor collects this layer separately from camera UI.
    override package func draw(with _: UIGraphicsContext) {}

    func drawOverlay(with context: UIGraphicsContext) {
        super.draw(with: context)
    }
}
