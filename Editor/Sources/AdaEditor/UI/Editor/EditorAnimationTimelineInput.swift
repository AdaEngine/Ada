@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorAnimationTimelineInput: UIViewRepresentable {
    let model: EditorAnimationTimelineModel
    func makeUIView(in _: Context) -> EditorAnimationTimelineInputView {
        let view = EditorAnimationTimelineInputView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: EditorAnimationTimelineInputView, in _: Context) {
        view.model = model
        model.onCancelPointer = { [weak view] in view?.abortPointer() }
    }
}

final class EditorAnimationTimelineInputView: UIView {
    weak var model: EditorAnimationTimelineModel?
    private var start: Point?
    private var operation = ""
    private var retainedSelection: Set<EditorAnimationTimelineModel.Key> = []
    private var originalSelection: Set<EditorAnimationTimelineModel.Key> = []
    private var epoch: UInt64 = 0

    func abortPointer() {
        if operation == "box" { model?.selectedKeys = originalSelection }
        operation = ""; start = nil
    }

    override func onMouseEvent(_ event: MouseEvent) {
        guard let model else { return }
        let point = event.mousePosition
        let labels = EditorAnimationTimeline.labelsWidth
        let ruler = EditorAnimationTimeline.rulerHeight
        let height = EditorAnimationTimeline.rowHeight
        if event.button == .scrollWheel {
            if event.modifierKeys.contains(.control) || event.modifierKeys.contains(.main) {
                let anchored = model.timeOffset + Double(max(0, point.x - labels) / model.pixelsPerSecond)
                model.pixelsPerSecond = max(8, min(20_000, model.pixelsPerSecond * pow(1.1, event.scrollDelta.y)))
                model.timeOffset = max(0, anchored - Double(max(0, point.x - labels) / model.pixelsPerSecond))
            } else if event.modifierKeys.contains(.shift) {
                model.timeOffset = max(0, model.timeOffset - Double(event.scrollDelta.y * 20 / model.pixelsPerSecond))
            } else {
                model.verticalOffset = max(0, min(max(0, Float(model.rows.count) * height - frame.height + ruler), model.verticalOffset - event.scrollDelta.y * height))
            }
            return
        }
        guard event.button == .left || event.phase == .cancelled else { return }
        if event.phase != .began, epoch != model.pointerEpoch {
            operation = ""; start = nil
            return
        }
        let rows = model.rows
        switch event.phase {
        case .began:
            epoch = model.pointerEpoch
            start = point
            retainedSelection = model.selectedKeys
            originalSelection = model.selectedKeys
            if point.y < ruler, point.x >= labels { operation = "seek"; model.seek(time(at: point.x)); return }
            let index = Int((point.y - ruler + model.verticalOffset) / height)
            guard rows.indices.contains(index), point.y >= ruler else { operation = ""; return }
            let row = rows[index]
            let additive = event.modifierKeys.contains(.control) || event.modifierKeys.contains(.main)
            if point.x < labels {
                if point.x < 22, row.channel == nil {
                    if !model.expandedChannels.insert(row.nodeID).inserted { model.expandedChannels.remove(row.nodeID) }
                } else {
                    model.selectNode(row.nodeID, additive: additive, range: event.modifierKeys.contains(.shift))
                    model.selectedTrackID = row.track?.id
                    model.selectedChannel = row.channel
                }
                operation = "label"
            } else if let (reference, key) = model.keys(in: row, timeRange: time(at: point.x - 7)...time(at: point.x + 7))
                .min(by: { abs(x($0.1.time) - point.x) < abs(x($1.1.time) - point.x) }), abs(x(key.time) - point.x) < 7 {
                let range = event.modifierKeys.contains(.shift)
                if !model.selectedKeys.contains(reference) || additive || range { model.selectKey(reference, additive: additive, range: range) }
                model.beginKeyDrag()
                operation = "keys"
            } else {
                operation = "box"
                if !additive { retainedSelection = []; model.selectedKeys = [] }
            }
        case .changed:
            change(point)
        case .ended:
            change(point)
            if operation == "keys" { model.endKeyDrag() }
            if operation == "box", let start, abs(start.x - point.x) + abs(start.y - point.y) < 4 { model.seek(time(at: point.x)) }
            model.marquee = nil
            operation = ""; start = nil
        case .cancelled:
            model.endKeyDrag(cancel: true)
            model.marquee = nil
            abortPointer()
        }
    }

    private func change(_ point: Point) {
        guard let model, let start else { return }
        switch operation {
        case "seek": model.seek(time(at: point.x))
        case "keys":
            let delta = Double((point.x - start.x) / model.pixelsPerSecond)
            model.dragDelta = model.snap > 0 ? (delta / model.snap).rounded() * model.snap : delta
        case "box":
            let left = max(EditorAnimationTimeline.labelsWidth, min(start.x, point.x))
            let top = max(EditorAnimationTimeline.rulerHeight, min(start.y, point.y))
            let right = min(frame.width, max(EditorAnimationTimeline.labelsWidth, max(start.x, point.x)))
            let bottom = min(frame.height, max(EditorAnimationTimeline.rulerHeight, max(start.y, point.y)))
            let rect = Rect(x: left, y: top, width: max(0, right - left), height: max(0, bottom - top))
            model.marquee = rect
            var selection = retainedSelection
            for (index, row) in model.rows.enumerated() {
                let y = EditorAnimationTimeline.rulerHeight + (Float(index) + 0.5) * EditorAnimationTimeline.rowHeight - model.verticalOffset
                guard y >= rect.minY, y <= rect.maxY else { continue }
                for (ref, _) in model.keys(in: row, timeRange: time(at: rect.minX)...time(at: rect.maxX)) { selection.insert(ref) }
            }
            model.selectedKeys = selection
        default: break
        }
    }

    private func time(at x: Float) -> Double {
        guard let model else { return 0 }
        return model.timeOffset + Double((x - EditorAnimationTimeline.labelsWidth) / max(1, model.pixelsPerSecond))
    }
    private func x(_ time: Double) -> Float {
        guard let model else { return 0 }
        return EditorAnimationTimeline.labelsWidth + Float(time - model.timeOffset) * model.pixelsPerSecond
    }
}
