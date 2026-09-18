@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math

struct EditorPreviewSurface: UIViewRepresentable {
    let previewView: UIView
    let zoom: Float
    let isInteractive: Bool

    func makeUIView(in _: Context) -> EditorPreviewHostView {
        EditorPreviewHostView()
    }

    func updateUIView(_ view: EditorPreviewHostView, in _: Context) {
        view.configure(previewView: previewView, zoom: zoom, isInteractive: isInteractive)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, view _: EditorPreviewHostView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class EditorPreviewHostView: UIView {
    private(set) var previewView: UIView?
    private(set) var zoom: Float = 1
    private(set) var isInteractive = false
    private(set) var contentSize: Size?
    private var activeMouseEvent: MouseEvent?
    private var activeTouches: Set<TouchEvent> = []

    override var acceptsKeyboardFocus: Bool { isInteractive }

    func configure(previewView: UIView, zoom: Float, isInteractive: Bool, contentSize: Size? = nil) {
        let minimumZoom: Float = contentSize == nil ? 0.25 : 0.02
        let resolvedZoom = zoom.isFinite ? min(max(zoom, minimumZoom), 3) : 1
        guard self.previewView !== previewView || self.zoom != resolvedZoom || self.isInteractive != isInteractive || self.contentSize != contentSize else {
            return
        }
        if self.isInteractive && (!isInteractive || self.previewView !== previewView), let activeMouseEvent {
            onMouseEvent(
                MouseEvent(
                    window: activeMouseEvent.window,
                    button: activeMouseEvent.button,
                    mousePosition: activeMouseEvent.mousePosition,
                    phase: .cancelled,
                    modifierKeys: activeMouseEvent.modifierKeys,
                    time: activeMouseEvent.time
                )
            )
        }
        if self.isInteractive && (!isInteractive || self.previewView !== previewView), !activeTouches.isEmpty {
            onTouchesEvent(
                Set(
                    activeTouches.map { touch in
                        TouchEvent(window: touch.window, location: touch.location, phase: .cancelled, time: touch.time, contactID: touch.contactID)
                    }
                )
            )
        }
        if self.previewView !== previewView {
            self.previewView?.removeFromParentView()
            self.previewView = previewView
            addSubview(previewView)
        }
        self.zoom = resolvedZoom
        self.contentSize = contentSize
        self.isInteractive = isInteractive
        isInteractionEnabled = isInteractive
        backgroundColor = .clear
        setNeedsLayout()
        setNeedsDisplay()
    }

    override func layoutSubviews() {
        previewView?.frame = Rect(origin: .zero, size: contentSize ?? bounds.size)
        super.layoutSubviews()
    }

    private var contentOrigin: Point {
        let content = contentSize ?? bounds.size
        return Point(x: (bounds.width - content.width * zoom) / 2, y: (bounds.height - content.height * zoom) / 2)
    }

    func previewPoint(from point: Point) -> Point {
        Point(x: (point.x - contentOrigin.x) / zoom, y: (point.y - contentOrigin.y) / zoom)
    }

    override func hitTest(_ point: Point, with _: any InputEvent) -> UIView? {
        guard
            isInteractive, !isHidden, bounds.contains(point: point),
            let previewView, previewView.bounds.contains(point: previewPoint(from: point))
        else {
            return nil
        }
        return self
    }

    override func draw(with context: UIGraphicsContext) {
        guard !isHidden, let previewView else {
            return
        }
        var recorded = UIGraphicsContext()
        recorded.environment = context.environment
        recorded.opacity = context.opacity
        recorded.windowId = context.windowId
        previewView.draw(with: recorded)
        let origin = contentOrigin
        let transform =
            context.transform
            * Transform3D(translation: [frame.minX + origin.x, -frame.minY - origin.y, 0])
            * Transform3D(scale: [zoom, zoom, 1])
        context.drawContents(of: recorded, transform: transform)
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard isInteractive else {
            return
        }
        if event.phase == .began {
            activeMouseEvent = event
        }
        if event.phase == .ended || event.phase == .cancelled {
            activeMouseEvent = nil
        }
        previewView?
            .onMouseEvent(
                MouseEvent(
                    window: event.window,
                    button: event.button,
                    scrollDelta: event.scrollDelta,
                    mousePosition: previewPoint(from: event.mousePosition),
                    phase: event.phase,
                    modifierKeys: event.modifierKeys,
                    time: event.time
                )
            )
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard isInteractive else {
            return
        }
        activeTouches = Set(touches.filter { $0.phase == .began || $0.phase == .moved })
        previewView?
            .onTouchesEvent(
                Set(
                    touches.map { touch in
                        TouchEvent(window: touch.window, location: previewPoint(from: touch.location), phase: touch.phase, time: touch.time, contactID: touch.contactID)
                    }
                )
            )
    }

    override func onKeyEvent(_ event: KeyEvent) {
        guard isInteractive else {
            return
        }
        previewView?.onKeyEvent(event)
    }

    override func onTextInputEvent(_ event: TextInputEvent) {
        guard isInteractive else {
            return
        }
        previewView?.onTextInputEvent(event)
    }

    override func onReceiveEvent(_ event: any InputEvent) {
        guard isInteractive else {
            return
        }
        previewView?.onReceiveEvent(event)
    }
}
