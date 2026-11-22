@_spi(Internal) import AdaInput
import Math

extension UIWindow {
    /// Routes this frame's input while retaining the raw event stream for scene consumers.
    func sendPendingInput(_ input: inout Input) {
        let events = input.eventsPool
        let coalescesHover = UIWindowManager.shared?.pointerIsCaptured(in: id) != true
        var previousWheel: MouseEvent?
        defer { if previousWheel != nil { ScrollViewNode.finishWheelBatch() } }
        for index in events.indices {
            let event = events[index]
            let wheel = event as? MouseEvent
            let isBatchableWheel = wheel?.window == id && wheel?.button == .scrollWheel && wheel?.phase == .changed
            if let preceding = previousWheel, !isBatchableWheel
                || preceding.mousePosition != wheel?.mousePosition
                || preceding.modifierKeys != wheel?.modifierKeys {
                ScrollViewNode.finishWheelBatch()
                previousWheel = nil
            }
            guard event.window == id else { continue }
            if isBatchableWheel, let wheel {
                if previousWheel == nil, index + 1 < events.count,
                   let next = events[index + 1] as? MouseEvent, next.window == id,
                   next.button == .scrollWheel, next.phase == .changed,
                   next.mousePosition == wheel.mousePosition, next.modifierKeys == wheel.modifierKeys {
                    ScrollViewNode.beginWheelBatch()
                    previousWheel = wheel
                }
            }
            if blocksScenePicking(for: event) {
                input.blockScenePicking(for: event)
            }
            if let mouse = event as? MouseEvent, mouse.phase == .changed,
                index + 1 < events.count,
                let next = events[index + 1] as? MouseEvent,
                next.window == mouse.window, next.phase == .changed, next.button == mouse.button,
                next.modifierKeys == mouse.modifierKeys {
                if (coalescesHover && mouse.button == .none) || coalescesTextSelection(for: mouse) {
                    continue
                }
                // Keep direction changes: crossing a divider's collapse threshold may
                // matter even if the pointer returns before the window draws again.
                if coalescesCapturedDrag(for: mouse), index > 0, let previous = events[index - 1] as? MouseEvent,
                    previous.window == mouse.window, previous.phase == .changed, previous.button == mouse.button,
                    previous.modifierKeys == mouse.modifierKeys,
                    isBetween(mouse.mousePosition.x, previous.mousePosition.x, next.mousePosition.x),
                    isBetween(mouse.mousePosition.y, previous.mousePosition.y, next.mousePosition.y) {
                    continue
                }
            }
            sendEvent(event)
        }
    }

    private func isBetween(_ point: Float, _ start: Float, _ end: Float) -> Bool {
        if start == end {
            return point == start
        }
        return point > min(start, end) && point < max(start, end)
    }
}
