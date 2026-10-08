import AdaInput
import AdaUtils
import Math

/// A numeric mouse/touch slider. The host binding owns the value; steps snap from the lower bound.
public struct Slider: View {
    private let value: Binding<Double>
    private let bounds: ClosedRange<Double>
    private let step: Double
    public init(value: Binding<Double>, in bounds: ClosedRange<Double> = 0...1, step: Double = 0) {
        self.value = value
        self.bounds = bounds
        self.step = step
    }
    public var body: some View {
        SliderSurface(value: value, bounds: bounds, step: step).frame(height: 32)
    }
}

private struct SliderSurface: UIViewRepresentable {
    let value: Binding<Double>
    let bounds: ClosedRange<Double>
    let step: Double
    func makeUIView(in _: Context) -> SliderHost { SliderHost() }
    func updateUIView(_ view: SliderHost, in context: Context) {
        view.value = value
        view.range = bounds
        view.step = step
        view.enabled = context.environment.isEnabled
        view.setNeedsDisplay()
    }
    func sizeThatFits(_ proposal: ProposedViewSize, view _: SliderHost, context _: Context) -> Size {
        Size(width: proposal.width ?? 200, height: 32)
    }
}

final class SliderHost: UIView {
    var value: Binding<Double>?
    var range: ClosedRange<Double> = 0...1
    var step: Double = 0
    var enabled = true
    private var mouseActive = false
    private var contact: RID?

    override func draw(in rect: Rect, with context: UIGraphicsContext) {
        let width = max(0, rect.width - 16)
        let span = range.upperBound - range.lowerBound
        let raw = value?.wrappedValue ?? range.lowerBound
        let fraction = raw.isFinite && span.isFinite && span > 0 ? min(1, max(0, (raw - range.lowerBound) / span)) : 0
        let x = rect.minX + 8 + Float(fraction) * width
        let color: Color = enabled ? .blue : .gray
        context.drawRect(Rect(x: rect.minX + 8, y: rect.midY - 2, width: width, height: 4), color: .gray)
        context.drawRect(Rect(x: rect.minX + 8, y: rect.midY - 2, width: x - rect.minX - 8, height: 4), color: color)
        context.drawEllipse(in: Rect(x: x - 8, y: rect.midY - 8, width: 16, height: 16), color: color)
    }
    override func onMouseEvent(_ event: MouseEvent) {
        guard enabled, contact == nil else {
            mouseActive = false
            return
        }
        if event.phase == .began { mouseActive = true }
        guard mouseActive else {
            return
        }
        if event.phase != .cancelled { move(event.mousePosition) }
        if event.phase == .ended || event.phase == .cancelled { mouseActive = false }
    }
    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard enabled, !mouseActive else {
            contact = nil
            return
        }
        for touch in touches {
            if touch.phase == .began, contact == nil { contact = touch.contactID }
            guard contact == touch.contactID else { continue }
            if touch.phase != .cancelled { move(touch.location) }
            if touch.phase == .ended || touch.phase == .cancelled { contact = nil }
        }
    }
    override func onFocusChanged(isFocused: Bool) { if !isFocused { mouseActive = false; contact = nil } }
    override func viewWillMove(to window: UIWindow?) { if window == nil { mouseActive = false; contact = nil } }
    private func move(_ point: Point) {
        let span = range.upperBound - range.lowerBound
        guard enabled, point.x.isFinite, bounds.width > 16, span.isFinite, span > 0 else {
            return
        }
        let fraction = min(1, max(0, Double((point.x - 8) / (bounds.width - 16))))
        var next = range.lowerBound + fraction * span
        if step.isFinite, step > 0 { next = range.lowerBound + ((next - range.lowerBound) / step).rounded() * step }
        value?.wrappedValue = min(range.upperBound, max(range.lowerBound, next))
        setNeedsDisplay()
    }
}
