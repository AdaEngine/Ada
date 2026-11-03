@_spi(Internal) import AdaInput

extension UIWindow {
    /// Routes this frame's input while retaining the raw event stream for scene consumers.
    func sendPendingInput(_ input: inout Input) {
        let events = input.eventsPool
        let coalescesHover = UIWindowManager.shared?.pointerIsCaptured(in: id) != true
        for index in events.indices where events[index].window == id {
            let event = events[index]
            if blocksScenePicking(for: event) {
                input.blockScenePicking(for: event)
            }
            // Only the last position in a consecutive hover or text-selection
            // burst can be presented. Other drags still receive every point.
            if let mouse = event as? MouseEvent, mouse.phase == .changed,
                (coalescesHover && mouse.button == .none) || coalescesTextSelection(for: mouse),
                index + 1 < events.count,
                let next = events[index + 1] as? MouseEvent,
                next.window == mouse.window, next.phase == .changed, next.button == mouse.button,
                next.modifierKeys == mouse.modifierKeys {
                continue
            }
            sendEvent(event)
        }
    }
}
