//
//  BrowserWindowManager.swift
//  AdaEngine
//

#if WASM && canImport(JavaScriptKit)
    import AdaECS
    @_spi(Internal) import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import JavaScriptKit
    import Math

    @MainActor
    final class BrowserWindowManager: UIWindowManager {
        private let screenManager: BrowserScreenManager
        private var eventClosures: [UIWindow.ID: [JSClosure]] = [:]
        private var resizeObservers: [UIWindow.ID: JSObject] = [:]
        private var surfaces: [UIWindow.ID: BrowserRenderSurface] = [:]

        init(screenManager: BrowserScreenManager) {
            self.screenManager = screenManager
            super.init()
        }

        override func createWindow(for window: UIWindow) {
            print("AdaEngine BrowserWindowManager createWindow")
            let surface = BrowserRenderSurface(windowId: window.id, requestedSize: window.configuration.frame.size)
            surfaces[window.id] = surface
            window.frame.size = surface.size
            window.systemWindow = BrowserSystemWindow(surface: surface, title: window.configuration.title ?? "AdaEngine")

            attachCanvas(surface.canvas)
            installEventHandlers(for: window, surface: surface)
            installResizeObserver(for: window, surface: surface)

            if unsafe RenderEngine.shared != nil {
                unsafe try? RenderEngine.shared.createWindow(window.id, for: surface, size: surface.logicalSize)
            }

            super.createWindow(for: window)
        }

        override func showWindow(_ window: UIWindow, isFocused: Bool) {
            if isFocused {
                setActiveWindow(window)
                _ = surfaces[window.id]?.canvas.focus?()
            }
            window.windowDidAppear()
        }

        override func closeWindow(_ window: UIWindow) {
            guard window.windowShouldClose() else {
                return
            }

            _ = resizeObservers[window.id]?.disconnect?()
            resizeObservers[window.id] = nil
            _ = surfaces[window.id]?.canvas.remove?()
            surfaces[window.id] = nil
            eventClosures[window.id] = nil
            removeWindow(window)
        }

        override func resizeWindow(_ window: UIWindow, size: Size) {
            guard let surface = surfaces[window.id] else {
                return
            }

            resize(window, surface: surface, to: size, updateWindowFrame: false)
        }

        override func setWindowMode(_ window: UIWindow, mode: UIWindow.Mode) {
            if mode == .fullscreen || mode == .fullScreenWindowed {
                _ = surfaces[window.id]?.canvas.requestFullscreen?()
            }
        }

        override func setMinimumSize(_: Size, for _: UIWindow) {}

        override func getScreen(for _: UIWindow) -> Screen? {
            screenManager.getMainScreen()
        }

        override func setCursorShape(_ shape: Input.CursorShape) {
            activeWindow.flatMap { surfaces[$0.id] }?.setCursorShape(shape)
        }

        override func getCursorShape() -> Input.CursorShape {
            .arrow
        }

        override func setCursorImage(for _: Input.CursorShape, texture _: Texture2D?, hotspot _: Vector2) {}

        override func setMouseMode(_ mode: Input.MouseMode) {
            guard let canvas = activeWindow.flatMap({ surfaces[$0.id]?.canvas }) else {
                return
            }

            switch mode {
            case .captured:
                _ = canvas.requestPointerLock?()
            case .hidden,
                .confinedHidden:
                canvas.style.cursor = .string("none")
            case .visible,
                .confined:
                canvas.style.cursor = .string("default")
            }
        }

        override func getMouseMode() -> Input.MouseMode {
            .visible
        }

        override func updateCursor() {}

        private func attachCanvas(_ canvas: JSObject) {
            print("AdaEngine BrowserWindowManager attachCanvas")
            let document = JSObject.global.document
            guard
                let container = document.getElementById("ada-canvas-root").object ?? document.body.object,
                let appendChild: (JSObject) -> JSValue = container.appendChild
            else {
                preconditionFailure("Browser document must provide a canvas container.")
            }
            _ = appendChild(canvas)
        }

        private func installEventHandlers(for window: UIWindow, surface: BrowserRenderSurface) {
            var closures: [JSClosure] = []
            let canvas = surface.canvas
            guard let browserWindow = JSObject.global.window.object else {
                preconditionFailure("Browser window is unavailable.")
            }

            closures.append(
                addEventListener("pointerdown", to: canvas) { [weak self, weak window, weak surface] event in
                    self?.handlePointer(event, window: window, surface: surface, phase: .began)
                }
            )
            closures.append(
                addEventListener("pointermove", to: canvas) { [weak self, weak window, weak surface] event in
                    self?.handlePointer(event, window: window, surface: surface, phase: .changed)
                }
            )
            closures.append(
                addEventListener("pointerup", to: canvas) { [weak self, weak window, weak surface] event in
                    self?.handlePointer(event, window: window, surface: surface, phase: .ended)
                }
            )
            closures.append(
                addEventListener("wheel", to: canvas) { [weak self, weak window, weak surface] event in
                    self?.handleWheel(event, window: window, surface: surface)
                }
            )
            closures.append(
                addEventListener("keydown", to: browserWindow) { [weak self, weak window] event in
                    self?.handleKey(event, window: window, status: .down)
                }
            )
            closures.append(
                addEventListener("keyup", to: browserWindow) { [weak self, weak window] event in
                    self?.handleKey(event, window: window, status: .up)
                }
            )
            closures.append(
                addEventListener("resize", to: browserWindow) { [weak self, weak window, weak surface] _ in
                    self?.resizeToViewport(window: window, surface: surface)
                }
            )
            if let visualViewport = JSObject.global.window.visualViewport.object {
                closures.append(
                    addEventListener("resize", to: visualViewport) { [weak self, weak window, weak surface] _ in
                        self?.resizeToViewport(window: window, surface: surface)
                    }
                )
            }

            eventClosures[window.id] = closures
        }

        private func installResizeObserver(for window: UIWindow, surface: BrowserRenderSurface) {
            guard let resizeObserverConstructor = JSObject.global.ResizeObserver.function else {
                return
            }

            let closure = JSClosure { [weak self, weak window, weak surface] _ in
                MainActor.assumeIsolated {
                    self?.resizeToViewport(window: window, surface: surface)
                }
                return .undefined
            }
            let observer = resizeObserverConstructor.new(closure)
            let document = JSObject.global.document
            let container = document.getElementById("ada-canvas-root").object ?? document.body.object
            if let container, let observe: (JSObject) -> JSValue = observer.observe {
                _ = observe(container)
            }
            eventClosures[window.id, default: []].append(closure)
            resizeObservers[window.id] = observer
        }

        private func resizeToViewport(window: UIWindow?, surface: BrowserRenderSurface?) {
            guard let window, let surface else {
                return
            }

            resize(window, surface: surface, to: BrowserRenderSurface.viewportSize(fallback: surface.size), updateWindowFrame: true)
        }

        private func resize(_ window: UIWindow, surface: BrowserRenderSurface, to size: Size, updateWindowFrame: Bool) {
            guard size.width > 0, size.height > 0 else {
                return
            }

            if surface.size == size {
                return
            }

            surface.resize(to: size)
            if updateWindowFrame {
                window.frame.size = size
                window.setNeedsLayout()
                window.setNeedsDisplay()
            }
            unsafe try? RenderEngine.shared?.resizeWindow(window.id, newSize: surface.logicalSize, scaleFactor: surface.scaleFactor)
        }

        private func addEventListener(
            _ name: String,
            to target: JSObject,
            handler: @escaping @MainActor (JSObject) -> Void
        ) -> JSClosure {
            let closure = JSClosure { arguments in
                guard let event = arguments.first?.object else {
                    return .undefined
                }

                MainActor.assumeIsolated {
                    handler(event)
                }

                return .undefined
            }
            guard let addEventListener: (String, JSClosure) -> JSValue = target.addEventListener else {
                preconditionFailure("JavaScript event targets must provide addEventListener.")
            }
            _ = addEventListener(name, closure)
            return closure
        }

        private func handlePointer(_ event: JSObject, window: UIWindow?, surface: BrowserRenderSurface?, phase: MouseEvent.Phase) {
            guard let window, let surface, let inputRef else {
                return
            }

            _ = event.preventDefault?()
            if phase == .began {
                setActiveWindow(window)
                _ = surface.canvas.focus?()
            }

            inputRef.wrappedValue.mousePosition = surface.location(from: event)
            inputRef.wrappedValue.receiveEvent(
                MouseEvent(
                    window: window.id,
                    button: mouseButton(from: event, phase: phase),
                    mousePosition: inputRef.wrappedValue.mousePosition,
                    phase: phase,
                    modifierKeys: KeyModifier(browserEvent: event),
                    time: Float(Time.absolute)
                )
            )
        }

        private func handleWheel(_ event: JSObject, window: UIWindow?, surface: BrowserRenderSurface?) {
            guard let window, let surface, let inputRef else {
                return
            }

            _ = event.preventDefault?()
            inputRef.wrappedValue.mousePosition = surface.location(from: event)
            inputRef.wrappedValue.receiveEvent(
                MouseEvent(
                    window: window.id,
                    button: .scrollWheel,
                    scrollDelta: Point(
                        x: Float(event.deltaX.number ?? 0),
                        y: Float(event.deltaY.number ?? 0)
                    ),
                    mousePosition: inputRef.wrappedValue.mousePosition,
                    phase: .changed,
                    modifierKeys: KeyModifier(browserEvent: event),
                    time: Float(Time.absolute)
                )
            )
        }

        private func mouseButton(from event: JSObject, phase: MouseEvent.Phase) -> MouseButton {
            if let button = event.button.number, let mappedButton = MouseButton(browserButton: Int(button)) {
                return mappedButton
            }

            if phase == .changed, let buttons = event.buttons.number {
                return MouseButton(browserButtons: Int(buttons))
            }

            return .none
        }

        private func handleKey(_ event: JSObject, window: UIWindow?, status: KeyEvent.Status) {
            guard let window = window ?? activeWindow, let inputRef else {
                return
            }

            _ = event.preventDefault?()
            let keyCode = KeyCode(browserEvent: event)
            let modifiers = KeyModifier(browserEvent: event)
            let time = Float(Time.absolute)

            inputRef.wrappedValue.receiveEvent(
                KeyEvent(
                    window: window.id,
                    keyCode: keyCode,
                    modifiers: modifiers,
                    status: status,
                    time: time,
                    isRepeated: event.repeat.boolean ?? false
                )
            )

            guard status == .down else {
                return
            }

            if keyCode == .backspace {
                inputRef.wrappedValue.receiveEvent(
                    TextInputEvent(
                        window: window.id,
                        text: "",
                        action: .deleteBackward,
                        time: time
                    )
                )
                return
            }

            guard
                let key = event.key.string,
                let textPayload = Self.textInputPayload(
                    key: key,
                    modifiers: modifiers
                )
            else {
                return
            }

            inputRef.wrappedValue.receiveEvent(
                TextInputEvent(
                    window: window.id,
                    text: textPayload,
                    action: .insert,
                    time: time
                )
            )
        }

        private static func textInputPayload(key: String, modifiers: KeyModifier) -> String? {
            if modifiers.contains(.main) || modifiers.contains(.control) {
                return nil
            }

            guard key.count == 1 else {
                return nil
            }

            let sanitizedText =
                key
                .replacingOccurrences(of: "\r\n", with: " ")
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")

            guard !sanitizedText.isEmpty else {
                return nil
            }

            let containsUnsupportedScalars = sanitizedText.unicodeScalars.contains { scalar in
                let value = scalar.value
                return value < 0x20 || value == 0x7F
            }

            return containsUnsupportedScalars ? nil : sanitizedText
        }
    }

    @MainActor
    final class BrowserRenderSurface: BrowserCanvasRenderSurface {
        let windowId: WindowID
        let canvas: JSObject

        var scaleFactor: Float {
            Float(JSObject.global.window.devicePixelRatio.number ?? 1)
        }

        var prefferedPixelFormat: PixelFormat {
            .bgra8
        }

        var logicalSize: SizeInt {
            SizeInt(width: Int(size.width), height: Int(size.height))
        }

        private(set) var size: Size

        init(windowId: WindowID, requestedSize: Size) {
            self.windowId = windowId
            let document = JSObject.global.document
            guard let canvas = document.createElement("canvas").object else {
                preconditionFailure("Browser document could not create a canvas.")
            }
            self.canvas = canvas
            self.size = Self.viewportSize(fallback: requestedSize)

            canvas.id = .string("ada-canvas-\(windowId)")
            canvas.tabIndex = .number(0)
            canvas.style.display = .string("block")
            canvas.style.width = .string("100%")
            canvas.style.height = .string("100%")
            canvas.style.touchAction = .string("none")
            canvas.style.userSelect = .string("none")
            resizeBackingStore()
        }

        func resize(to newSize: Size) {
            self.size = newSize
            resizeBackingStore()
        }

        func location(from event: JSObject) -> Point {
            guard
                let getBoundingClientRect: () -> JSValue = canvas.getBoundingClientRect,
                let rect = getBoundingClientRect().object
            else {
                return .zero
            }
            let cssWidth = rect.width.number ?? Double(size.width)
            let cssHeight = rect.height.number ?? Double(size.height)
            let xScale = cssWidth > 0 ? Double(size.width) / cssWidth : 1
            let yScale = cssHeight > 0 ? Double(size.height) / cssHeight : 1
            return Point(
                x: Float(((event.clientX.number ?? 0) - (rect.left.number ?? 0)) * xScale),
                y: Float(((event.clientY.number ?? 0) - (rect.top.number ?? 0)) * yScale)
            )
        }

        func setCursorShape(_ shape: Input.CursorShape) {
            canvas.style.cursor = .string(shape.browserCSSCursor)
        }

        static func viewportSize(fallback: Size = .zero) -> Size {
            let window = JSObject.global.window
            let document = JSObject.global.document
            let container = document.getElementById("ada-canvas-root").object ?? document.body.object
            let visualViewport = window.visualViewport.object

            let widthCandidates = [
                container?.clientWidth.number,
                visualViewport?.width.number,
                window.innerWidth.number,
                fallback.width > 0 ? Double(fallback.width) : nil,
            ]
            let heightCandidates = [
                container?.clientHeight.number,
                visualViewport?.height.number,
                window.innerHeight.number,
                fallback.height > 0 ? Double(fallback.height) : nil,
            ]
            let width = widthCandidates.compactMap { $0 }.first { $0 > 0 } ?? 800
            let height = heightCandidates.compactMap { $0 }.first { $0 > 0 } ?? 600

            return Size(
                width: Float(width),
                height: Float(height)
            )
        }

        private func resizeBackingStore() {
            let scale = Double(scaleFactor)
            canvas.width = .number(max((Double(size.width) * scale).rounded(), 1))
            canvas.height = .number(max((Double(size.height) * scale).rounded(), 1))
        }
    }

    @MainActor
    final class BrowserSystemWindow: SystemWindow {
        private let surface: BrowserRenderSurface

        var title: String {
            get { JSObject.global.document.title.string ?? "" }
            set { JSObject.global.document.title = .string(newValue) }
        }

        var size: Size {
            get { surface.logicalSize.toSize() }
            set { surface.resize(to: newValue) }
        }

        var position: Point = .zero

        init(surface: BrowserRenderSurface, title: String) {
            self.surface = surface
            self.title = title
        }
    }

    extension SizeInt {
        private func toSize() -> Size {
            Size(width: Float(width), height: Float(height))
        }
    }

    extension KeyModifier {
        private init(browserEvent event: JSObject) {
            self.init()
            if event.shiftKey.boolean == true {
                insert(.shift)
            }
            if event.ctrlKey.boolean == true {
                insert(.control)
            }
            if event.metaKey.boolean == true {
                insert(.main)
            }
            if event.altKey.boolean == true {
                insert(.alt)
            }
        }
    }

    extension KeyCode {
        private init(browserEvent event: JSObject) {
            let key = event.key.string ?? ""
            if key.count == 1, let scalar = key.lowercased().unicodeScalars.first {
                self = KeyCode(rawValue: String(scalar)) ?? .none
                return
            }

            switch key {
            case "Enter": self = .enter
            case "Escape": self = .escape
            case "Backspace": self = .backspace
            case "Tab": self = .tab
            case " ": self = .space
            case "Shift": self = .shift
            case "Control": self = .ctrl
            case "Alt": self = .alt
            case "Meta": self = .meta
            case "CapsLock": self = .capslock
            case "Delete": self = .delete
            case "Home": self = .home
            case "PageUp": self = .pageUp
            case "PageDown": self = .pageDown
            case "ArrowLeft": self = .arrowLeft
            case "ArrowRight": self = .arrowRight
            case "ArrowUp": self = .arrowUp
            case "ArrowDown": self = .arrowDown
            case "Insert": self = .insert
            default: self = KeyCode(rawValue: key) ?? .none
            }
        }
    }

    extension MouseButton {
        private init?(browserButton: Int) {
            switch browserButton {
            case 0:
                self = .left
            case 1:
                self = .middle
            case 2:
                self = .right
            default:
                return nil
            }
        }

        private init(browserButtons: Int) {
            if browserButtons & 1 != 0 {
                self = .left
            } else if browserButtons & 4 != 0 {
                self = .middle
            } else if browserButtons & 2 != 0 {
                self = .right
            } else {
                self = .none
            }
        }
    }

    extension Input.CursorShape {
        private var browserCSSCursor: String {
            switch self {
            case .arrow: "default"
            case .pointingHand: "pointer"
            case .iBeam: "text"
            case .wait,
                .busy:
                "wait"
            case .cross: "crosshair"
            case .drag,
                .drop:
                "grab"
            case .resizeLeft,
                .resizeRight,
                .resizeLeftRight:
                "ew-resize"
            case .resizeUp,
                .resizeDown,
                .resizeUpDown:
                "ns-resize"
            case .move: "move"
            case .forbidden: "not-allowed"
            case .help: "help"
            }
        }
    }
#endif
