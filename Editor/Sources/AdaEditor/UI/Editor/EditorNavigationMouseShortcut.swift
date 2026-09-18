#if canImport(AppKit)
    import AppKit
#endif

@MainActor
final class EditorNavigationMouseShortcutMonitor {
    enum Direction: Equatable {
        case back
        case forward
    }

    static let shared = EditorNavigationMouseShortcutMonitor()

    private var backAction: (() -> Void)?
    private var forwardAction: (() -> Void)?

    #if canImport(AppKit)
        private var eventMonitor: Any?
    #endif

    private init() {}

    func start(back: @escaping () -> Void, forward: @escaping () -> Void) {
        backAction = back
        forwardAction = forward

        #if canImport(AppKit)
            guard eventMonitor == nil else {
                return
            }

            eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { [weak self] event in
                let buttonNumber = event.buttonNumber
                let wasHandled = MainActor.assumeIsolated {
                    self?.handle(buttonNumber: buttonNumber) ?? false
                }
                return wasHandled ? nil : event
            }
        #endif
    }

    func stop() {
        backAction = nil
        forwardAction = nil

        #if canImport(AppKit)
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        #endif
    }

    static func direction(forButtonNumber buttonNumber: Int) -> Direction? {
        switch buttonNumber {
        case 3:
            .back
        case 4:
            .forward
        default:
            nil
        }
    }

    private func handle(buttonNumber: Int) -> Bool {
        guard let direction = Self.direction(forButtonNumber: buttonNumber) else {
            return false
        }

        switch direction {
        case .back:
            backAction?()
        case .forward:
            forwardAction?()
        }
        return true
    }
}
