@_spi(AdaEngine) import AdaEngine

#if canImport(AppKit)
    import AppKit
#endif

struct EditorDoubleShiftDetector {
    static let maximumInterval: Float = 0.5

    private(set) var lastPressTime: Float?

    mutating func registerPress(at time: Float, isRepeated: Bool = false) -> Bool {
        guard !isRepeated else {
            return false
        }

        guard let lastPressTime else {
            self.lastPressTime = time
            return false
        }

        let interval = time - lastPressTime
        guard interval >= 0, interval <= Self.maximumInterval else {
            self.lastPressTime = time
            return false
        }

        self.lastPressTime = nil
        return true
    }

    mutating func cancel() {
        lastPressTime = nil
    }
}

@MainActor
final class EditorSearchShortcutMonitor {
    static let shared = EditorSearchShortcutMonitor()

    private var subscriberCount = 0
    private var detector = EditorDoubleShiftDetector()

    #if canImport(AppKit)
        private var eventMonitor: Any?
        private var pressedShiftKeyCodes: Set<UInt16> = []
    #endif

    private init() {}

    func start() {
        subscriberCount += 1

        #if canImport(AppKit)
            guard eventMonitor == nil else {
                return
            }

            eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
            ) { [weak self] event in
                MainActor.assumeIsolated {
                    self?.handle(event)
                }
                return event
            }
        #endif
    }

    func stop() {
        subscriberCount = max(0, subscriberCount - 1)
        guard subscriberCount == 0 else {
            return
        }

        detector.cancel()

        #if canImport(AppKit)
            pressedShiftKeyCodes.removeAll(keepingCapacity: true)
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
                self.eventMonitor = nil
            }
        #endif
    }

    #if canImport(AppKit)
        private func handle(_ event: NSEvent) {
            switch event.type {
            case .flagsChanged where event.keyCode == 0x38 || event.keyCode == 0x3C:
                if pressedShiftKeyCodes.remove(event.keyCode) == nil {
                    let startsNewPress = pressedShiftKeyCodes.isEmpty
                    pressedShiftKeyCodes.insert(event.keyCode)
                    if startsNewPress, detector.registerPress(at: Float(event.timestamp)) {
                        focusSearchField()
                    }
                }
            case .flagsChanged,
                .keyDown,
                .leftMouseDown,
                .rightMouseDown,
                .otherMouseDown:
                detector.cancel()
            default:
                break
            }
        }
    #endif

    @discardableResult
    func focusSearchField(identifier: String = EditorTopToolbar.searchAccessibilityIdentifier) -> Bool {
        guard let window = UIWindowManager.shared?.activeWindow else {
            return false
        }

        return focusSearchField(in: window.uiInspectableContainers(), identifier: identifier)
    }

    func focusSearchField(
        in containers: [any UIInspectableViewContainer],
        identifier: String = EditorTopToolbar.searchAccessibilityIdentifier
    ) -> Bool {
        let selector = UINodeSelector.accessibilityIdentifier(identifier)
        for container in containers {
            guard
                let searchNode = try? container.uiNode(matching: selector),
                let focusableNode = searchNode.firstFocusableDescendant
            else {
                continue
            }

            do {
                _ = try container.uiFocusNode(matching: .runtimeID(focusableNode.runtimeId))
                return true
            } catch {
                continue
            }
        }

        return false
    }
}

extension UINodeSnapshot {
    var firstFocusableDescendant: UINodeSnapshot? {
        if canBecomeFocused {
            return self
        }

        for child in children {
            if let match = child.firstFocusableDescendant {
                return match
            }
        }

        return nil
    }
}
