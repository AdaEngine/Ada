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
            // Only the last position in a consecutive hover burst can be presented.
            // Keep presses, drags, scrolling, modifier changes and other input in order.
            if coalescesHover, let mouse = event as? MouseEvent, mouse.phase == .changed, mouse.button == .none,
                index + 1 < events.count,
                let next = events[index + 1] as? MouseEvent,
                next.window == mouse.window, next.phase == .changed, next.button == .none,
                next.modifierKeys == mouse.modifierKeys {
                continue
            }
            sendEvent(event)
        }
    }
}
