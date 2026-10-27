@_spi(AdaEngine) import AdaEngine
import Foundation

/// The representable receives canvas-local events, independent of window and sidebar offsets.
struct EditorNodeCanvasInput: UIViewRepresentable {
    let geometry: EditorNodeCanvasGeometry
    let wires: [EditorNodeCanvasWire]
    let selection: Set<String>
    let state: EditorNodeCanvasState
    let interaction: EditorNodeCanvasInteraction?

    func makeUIView(in _: Context) -> EditorNodeCanvasInputView {
        let view = EditorNodeCanvasInputView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }

    func updateUIView(_ view: EditorNodeCanvasInputView, in _: Context) {
        view.input = self
    }
}

final class EditorNodeCanvasInputView: UIView {
    var input: EditorNodeCanvasInput?
    private var start: Vector2?
    private var button: MouseButton?

    override func onMouseEvent(_ event: MouseEvent) {
        guard let input else { return }
        // Cursor/anchor changes only affect the retained Canvas drawing, not the view tree.
        // Request a frame for movement AND release, including a rejected or cancelled wire.
        defer { setNeedsDisplay() }
        let point = Vector2(event.mousePosition.x, event.mousePosition.y)
        if event.button == .scrollWheel {
            input.state.zoom(by: pow(1.1, event.scrollDelta.y), around: point)
            return
        }
        switch event.phase {
        case .began:
            guard event.button == .left || event.button == .middle else { return }
            start = point
            button = event.button
            drag(to: point)
        case .changed:
            if event.button == .none {
                finish(at: point)
            } else if event.button == button {
                drag(to: point)
            }
        case .ended:
            if event.button == button {
                drag(to: point)
                finish(at: point)
            }
        case .cancelled:
            input.interaction?.abort()
            start = nil
            button = nil
        }
    }

    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        guard let touch = touches.first else { return }
        defer { setNeedsDisplay() }
        let point = Vector2(touch.location.x, touch.location.y)
        switch touch.phase {
        case .began:
            start = point
            drag(to: point)
        case .moved: drag(to: point)
        case .ended:
            drag(to: point)
            finish(at: point)
        case .cancelled:
            input?.interaction?.abort()
            start = nil
        default: break
        }
    }

    private func drag(to point: Vector2) {
        guard let start, let input else { return }
        input.interaction?.drag(
            from: start, to: point, geometry: currentGeometry(input), wires: input.wires,
            selection: input.selection, state: input.state, panning: button == .middle
        )
    }

    private func finish(at point: Vector2) {
        guard start != nil, let input else { return }
        input.interaction?.end(at: point, geometry: currentGeometry(input))
        start = nil
        button = nil
    }

    private func currentGeometry(_ input: EditorNodeCanvasInput) -> EditorNodeCanvasGeometry {
        .init(nodes: input.geometry.nodes, pan: input.state.pan, zoom: input.state.zoom)
    }
}
