@_spi(AdaEngine) import AdaEngine

#if canImport(AppKit)
    import AppKit
#endif

struct EditorDoubleShiftDetector {
    static let maximumInterval: Float = 0.5

    private(set) var lastPressTime: Float?
    private var isShiftPressed = false

    mutating func register(_ event: KeyEvent) -> Bool {
        guard event.keyCode == .shift else {
            lastPressTime = nil
            return false
        }
        guard event.status == .down else {
            isShiftPressed = event.modifiers.contains(.shift)
            return false
        }
        guard !event.isRepeated, !isShiftPressed else { return false }
        isShiftPressed = true
        guard event.modifiers.subtracting([.shift, .capsLock]).isEmpty else {
            lastPressTime = nil
            return false
        }
        return registerPress(at: event.time)
    }

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
        isShiftPressed = false
    }
}

@MainActor
final class EditorSearchShortcutMonitor {
    static let shared = EditorSearchShortcutMonitor()

    private var subscriberCount = 0
    private var detector = EditorDoubleShiftDetector()
    private var inputWindowID: UIWindow.ID?

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
        inputWindowID = nil

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

    /// Observe the parsed input before focused controls receive the frame's events.
    func processInput(_ input: Input, in window: UIWindow?) {
        guard subscriberCount > 0, let window else {
            detector.cancel()
            inputWindowID = nil
            return
        }
        if inputWindowID != window.id {
            detector.cancel()
            inputWindowID = window.id
        }
        for event in input.getInputEvents() where event.window == window.id {
            if let key = event as? KeyEvent {
                if detector.register(key) {
                    _ = focusSearchField(in: window.uiInspectableContainers())
                }
            } else if let mouse = event as? MouseEvent, mouse.phase == .began, mouse.button != .none {
                detector.cancel()
            } else if let touch = event as? TouchEvent, touch.phase == .began {
                detector.cancel()
            }
        }
    }

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

/// Install after application scheduler setup so startup cannot replace the system.
struct EditorSearchShortcutPlugin: Plugin {
    func setup(in app: AppWorlds) {
        app.addSystem(EditorSearchShortcutInputSystem.self, on: .preUpdate)
    }
}

/// Windows delivers modifier keys through AdaInput instead of NSEvent.
@PlainSystem(dependencies: [.after(InputEventParseSystem.self), .before(UpdateWindowManagerSystem.self)])
struct EditorSearchShortcutInputSystem {
    @Res<Input> private var input
    @Res<WindowManagerResource> private var windows

    init(world _: World) {}

    @MainActor
    func update(context _: UpdateContext) {
        EditorSearchShortcutMonitor.shared.processInput(input, in: windows.windowManager.activeWindow)
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
