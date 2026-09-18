//
//  WindowsWindowManager.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/29/22.
//

#if os(Windows)
    import AdaECS
    @_spi(Internal) import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Dispatch
    import Foundation
    import Math
    import WinSDK

    // Windows cursor resource identifiers
    nonisolated(unsafe) private let IDC_ARROW: LPCWSTR? = unsafe UnsafePointer<WCHAR>(bitPattern: UInt(32512))
    private let adaEngineWorkMessage = UINT(WM_APP + 1)
    nonisolated(unsafe) private var windowMinimumSizes: [UIWindow.ID: Size] = [:]

    // Static storage for window class name (must persist for RegisterClassW)
    private let windowClassName: [WCHAR] = "AdaEngineWindow".wide
    private var windowClassNamePtr: LPCWSTR? {
        return unsafe windowClassName.withUnsafeBufferPointer { $0.baseAddress }
    }

    @safe
    final class WindowsWindowManager: UIWindowManager {
        private unowned let screenManager: WindowsScreenManager
        private let uiThread = WindowsUIThread()
        private var windowHandles: [UIWindow.ID: HWND] = unsafe [:]
        private var textInputDecoderStates: [UIWindow.ID: WindowsUTF16TextInputDecoder.State] = [:]
        private var windowsSynchronizingFromSystem: Set<UIWindow.ID> = []

        init(_ screenManager: WindowsScreenManager) {
            self.screenManager = screenManager
            super.init()
        }

        override func createWindow(for window: UIWindow) {
            let minSize = window.configuration.minimumSize

            let frame = window.frame
            let size =
                frame.size == .zero
                ? minSize
                : Size(
                    width: max(frame.size.width, minSize.width),
                    height: max(frame.size.height, minSize.height)
                )

            let width = Int32(size.width)
            let height = Int32(size.height)
            let initialScale = screenManager.getMainScreen()?.scale ?? 1
            let initialDPI = UINT(max((initialScale * 96).rounded(), 96))

            // Create Windows surface for rendering
            let sizeInt = SizeInt(width: Int(size.width), height: Int(size.height))

            let hwnd = self.uiThread.sync {
                let className = "AdaEngineWindow"
                let hInstance = unsafe GetModuleHandleW(nil)

                // Register window class if not already registered
                var wc = unsafe WNDCLASSW()
                unsafe wc.lpfnWndProc = unsafe WindowsWindowProc
                unsafe wc.hInstance = unsafe hInstance
                unsafe wc.lpszClassName = windowClassNamePtr
                unsafe wc.hCursor = LoadCursorW(nil, IDC_ARROW)
                unsafe wc.hbrBackground = UnsafeMutablePointer<HBRUSH__>(bitPattern: UInt(COLOR_WINDOW + 1))
                unsafe RegisterClassW(&wc)

                // Calculate window size including non-client area
                var windowStyle = DWORD(WS_OVERLAPPEDWINDOW)
                if !window.configuration.isResizable {
                    windowStyle &= ~DWORD(WS_THICKFRAME | WS_MAXIMIZEBOX)
                }
                var rect = RECT(
                    left: 0,
                    top: 0,
                    right: LONG((Float(width) * initialScale).rounded()),
                    bottom: LONG((Float(height) * initialScale).rounded())
                )
                unsafe AdjustWindowRectExForDpi(&rect, windowStyle, false, 0, initialDPI)
                let windowWidth = rect.right - rect.left
                let windowHeight = rect.bottom - rect.top

                guard
                    let hwnd = unsafe CreateWindowExW(
                        0,
                        className.wide,
                        window.title.wide,
                        windowStyle,
                        CW_USEDEFAULT,
                        CW_USEDEFAULT,
                        windowWidth,
                        windowHeight,
                        nil,
                        nil,
                        hInstance,
                        Unmanaged.passUnretained(self).toOpaque()
                    )
                else {
                    fatalError("Failed to create window")
                }

                let windowPtr = unsafe Unmanaged.passUnretained(window).toOpaque()
                let ptrValue = UInt64(UInt(bitPattern: OpaquePointer(windowPtr)))
                unsafe SetWindowLongPtrW(hwnd, GWLP_USERDATA, LONG_PTR(bitPattern: ptrValue))
                return hwnd
            }

            let windowsSurface = unsafe WindowsSurface(windowId: window.id, windowHwnd: hwnd)
            unsafe try? RenderEngine.shared.createWindow(window.id, for: windowsSurface, size: sizeInt)

            // Store window handle
            unsafe self.windowHandles[window.id] = hwnd

            let systemWindow = unsafe WindowsSystemWindow(hwnd: hwnd, surface: windowsSurface)
            window.systemWindow = systemWindow
            unsafe windowMinimumSizes[window.id] = minSize
            window.minSize = minSize
            window.setWindowMode(window.configuration.mode)
            window.userInterfaceIdiom = .desktop

            super.createWindow(for: window)
        }

        override func showWindow(_ window: UIWindow, isFocused: Bool) {
            guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                fatalError("System window not exist.")
            }

            if isFocused {
                self.uiThread.sync {
                    unsafe ShowWindow(systemWindow.hwnd, SW_SHOW)
                    unsafe SetForegroundWindow(systemWindow.hwnd)
                    unsafe SetFocus(systemWindow.hwnd)
                }
            } else {
                _ = self.uiThread.sync {
                    unsafe ShowWindow(systemWindow.hwnd, SW_SHOWNOACTIVATE)
                }
            }

            window.windowDidAppear()
            if isFocused {
                self.setActiveWindow(window)
            }
        }

        override func setWindowMode(_ window: UIWindow, mode: UIWindow.Mode) {
            guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                fatalError("System window not exist.")
            }

            self.uiThread.sync {
                let hwnd = unsafe systemWindow.hwnd
                let style = unsafe GetWindowLongW(hwnd, GWL_STYLE)

                switch mode {
                case .windowed:
                    if window.isFullscreen {
                        unsafe SetWindowLongW(hwnd, GWL_STYLE, style | Int32(WS_OVERLAPPEDWINDOW))
                        unsafe ShowWindow(hwnd, SW_RESTORE)
                        window.isFullscreen = false
                    }
                case .fullscreen:
                    if !window.isFullscreen {
                        unsafe SetWindowLongW(hwnd, GWL_STYLE, style & ~Int32(WS_OVERLAPPEDWINDOW))
                        unsafe ShowWindow(hwnd, SW_MAXIMIZE)
                        window.isFullscreen = true
                    }
                case .fullScreenWindowed:
                    unsafe SetWindowLongW(hwnd, GWL_STYLE, style | Int32(WS_OVERLAPPEDWINDOW))
                    unsafe ShowWindow(hwnd, SW_MAXIMIZE)
                    window.isFullscreen = false
                }
            }
        }

        override func closeWindow(_ window: UIWindow) {
            guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                fatalError("System window not exist.")
            }

            self.resetTextInputDecoderState(for: window.id)
            unsafe windowMinimumSizes.removeValue(forKey: window.id)
            self.removeWindow(window, setActiveAnotherIfNeeded: true)
            _ = self.uiThread.sync {
                unsafe DestroyWindow(systemWindow.hwnd)
            }
        }

        override func resizeWindow(_ window: UIWindow, size: Size) {
            guard !windowsSynchronizingFromSystem.contains(window.id) else {
                return
            }

            guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                return
            }

            self.uiThread.sync {
                let scaleFactor = getWindowScaleFactor(systemWindow.hwnd)
                let dpi = UINT(max((scaleFactor * 96).rounded(), 96))
                var style = DWORD(WS_OVERLAPPEDWINDOW)
                if !window.configuration.isResizable {
                    style &= ~DWORD(WS_THICKFRAME | WS_MAXIMIZEBOX)
                }
                var rect = RECT()
                unsafe GetClientRect(systemWindow.hwnd, &rect)
                rect.right = LONG((size.width * scaleFactor).rounded())
                rect.bottom = LONG((size.height * scaleFactor).rounded())

                unsafe AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
                unsafe SetWindowPos(
                    systemWindow.hwnd,
                    nil,
                    0,
                    0,
                    rect.right - rect.left,
                    rect.bottom - rect.top,
                    UINT(SWP_NOMOVE | SWP_NOZORDER)
                )
            }
        }

        override func setMinimumSize(_ size: Size, for window: UIWindow) {
            guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                fatalError("System window not exist.")
            }

            unsafe windowMinimumSizes[window.id] = size

            let currentSize = systemWindow.size
            let clampedSize = Size(
                width: max(currentSize.width, size.width),
                height: max(currentSize.height, size.height)
            )

            if clampedSize != currentSize {
                resizeWindow(window, size: clampedSize)
            }
        }

        override func getScreen(for window: UIWindow) -> Screen? {
            guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                return nil
            }

            guard let hMonitor = unsafe MonitorFromWindow(systemWindow.hwnd, UInt32(MONITOR_DEFAULTTONEAREST)) else {
                return nil
            }
            return unsafe screenManager.makeScreen(from: hMonitor)
        }

        override func setCursorShape(_: Input.CursorShape) {
            // TODO: Implement cursor shape changes
        }

        override func updateCursor() {
            // TODO: Implement cursor updates
        }

        override func getCursorShape() -> Input.CursorShape {
            return .arrow
        }

        override func setCursorImage(for _: Input.CursorShape, texture _: Texture2D?, hotspot _: Vector2) {
            // TODO: Implement custom cursor images
        }

        override func setMouseMode(_: Input.MouseMode) {
            // TODO: Implement mouse mode changes
        }

        override func getMouseMode() -> Input.MouseMode {
            return .visible
        }

        func findWindow(for hwnd: HWND) -> UIWindow? {
            return self.windows.first {
                if let systemWindow = $0.systemWindow as? WindowsSystemWindow {
                    return unsafe systemWindow.hwnd == hwnd
                }
                return false
            }
        }

        func decodeTextInputScalar(from codeUnit: UInt16, for windowId: UIWindow.ID) -> UnicodeScalar? {
            var state = self.textInputDecoderStates[windowId] ?? .init()
            let scalar = WindowsUTF16TextInputDecoder.decode(codeUnit: codeUnit, state: &state)

            if state.pendingHighSurrogate == nil {
                self.textInputDecoderStates.removeValue(forKey: windowId)
            } else {
                self.textInputDecoderStates[windowId] = state
            }

            return scalar
        }

        func resetTextInputDecoderState(for windowId: UIWindow.ID) {
            self.textInputDecoderStates.removeValue(forKey: windowId)
        }

        func synchronizeRenderMetrics(
            for window: UIWindow,
            sizeInt: SizeInt,
            scaleFactor: Float,
            updateWindowFrame: Bool
        ) {
            let newSize = sizeInt.toSize()

            if updateWindowFrame && window.frame.size != newSize {
                windowsSynchronizingFromSystem.insert(window.id)
                defer {
                    windowsSynchronizingFromSystem.remove(window.id)
                }
                window.frame = Rect(origin: .zero, size: newSize)
            }

            window.setNeedsLayout()
            unsafe try? RenderEngine.shared.resizeWindow(
                window.id,
                newSize: sizeInt,
                scaleFactor: scaleFactor
            )
        }
    }

    // MARK: - Input Handling Helpers

    enum WindowsUTF16TextInputDecoder {
        struct State {
            var pendingHighSurrogate: UInt16?
        }

        static func decode(codeUnit: UInt16, state: inout State) -> UnicodeScalar? {
            if (0xD800...0xDBFF).contains(codeUnit) {
                state.pendingHighSurrogate = codeUnit
                return nil
            }

            if (0xDC00...0xDFFF).contains(codeUnit) {
                guard let highSurrogate = state.pendingHighSurrogate else {
                    return nil
                }

                state.pendingHighSurrogate = nil
                let high = UInt32(highSurrogate - 0xD800)
                let low = UInt32(codeUnit - 0xDC00)
                let scalarValue = 0x10000 + (high << 10) + low
                return UnicodeScalar(scalarValue)
            }

            state.pendingHighSurrogate = nil
            return UnicodeScalar(UInt32(codeUnit))
        }
    }

    private func translateWindowsKeyCode(vkCode: UInt16) -> KeyCode {
        WindowsKeyboard.shared.translateKey(from: vkCode)
    }

    private func getWindowsKeyModifiers() -> KeyModifier {
        var modifiers: KeyModifier = []

        // let shiftState = Int32(bitPattern: UInt32(GetKeyState(0x10))) // VK_SHIFT
        // if (shiftState & 0x8000) != 0 {
        //     modifiers.insert(.shift)
        // }
        // let controlState = Int32(bitPattern: UInt32(GetKeyState(0x11))) // VK_CONTROL
        // if (controlState & 0x8000) != 0 {
        //     modifiers.insert(.control)
        // }
        // let menuState = Int32(bitPattern: UInt32(GetKeyState(0x12))) // VK_MENU
        // if (menuState & 0x8000) != 0 {
        //     modifiers.insert(.alt)
        // }
        // let lwinState = Int32(bitPattern: UInt32(GetKeyState(0x5B))) // VK_LWIN
        // let rwinState = Int32(bitPattern: UInt32(GetKeyState(0x5C))) // VK_RWIN
        // if (lwinState & 0x8000) != 0 || (rwinState & 0x8000) != 0 {
        //     modifiers.insert(.main)
        // }
        // let capitalState = Int32(bitPattern: UInt32(GetKeyState(0x14))) // VK_CAPITAL
        // if (capitalState & 0x0001) != 0 {
        //     modifiers.insert(.capsLock)
        // }

        return modifiers
    }

    private func getCurrentTime() -> AdaUtils.TimeInterval {
        return AdaUtils.TimeInterval(GetTickCount64()) / 1000.0
    }

    private func getWindowScaleFactor(_ hwnd: HWND) -> Float {
        let dpi = unsafe GetDpiForWindow(hwnd)
        guard dpi > 0 else {
            return 1
        }
        return max(Float(dpi) / 96.0, 1)
    }

    private func adjustedWindowSize(forClientSize size: Size, hwnd: HWND, scaleFactor: Float) -> (width: LONG, height: LONG) {
        let dpi = UINT(max((scaleFactor * 96).rounded(), 96))
        let style = DWORD(unsafe GetWindowLongW(hwnd, GWL_STYLE))
        let exStyle = DWORD(unsafe GetWindowLongW(hwnd, GWL_EXSTYLE))
        var rect = RECT(
            left: 0,
            top: 0,
            right: LONG((size.width * scaleFactor).rounded()),
            bottom: LONG((size.height * scaleFactor).rounded())
        )
        unsafe AdjustWindowRectExForDpi(&rect, style, false, exStyle, dpi)
        return (rect.right - rect.left, rect.bottom - rect.top)
    }

    private func logicalSize(fromPhysicalWidth width: UInt16, height: UInt16, scaleFactor: Float) -> SizeInt {
        SizeInt(
            width: max(Int((Float(width) / scaleFactor).rounded()), 1),
            height: max(Int((Float(height) / scaleFactor).rounded()), 1)
        )
    }

    private func logicalMousePosition(
        lParam: LPARAM,
        hwnd: HWND,
        scaleFactor: Float,
        isScreenPosition: Bool = false
    ) -> Point {
        var point = POINT(
            x: LONG(Int16(truncatingIfNeeded: lParam & 0xFFFF)),
            y: LONG(Int16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF))
        )

        if isScreenPosition {
            unsafe ScreenToClient(hwnd, &point)
        }

        return Point(Float(point.x) / scaleFactor, Float(point.y) / scaleFactor)
    }

    private final class WindowsUIThread: @unchecked Sendable {
        private let ready = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var workItems: [() -> Void] = []
        private var threadId: DWORD = 0

        init() {
            Thread.detachNewThread { [weak self] in
                self?.run()
            }
            ready.wait()
        }

        func sync<T>(_ work: @escaping () -> T) -> T {
            if GetCurrentThreadId() == threadId {
                return work()
            }

            let semaphore = DispatchSemaphore(value: 0)
            var result: T?
            enqueue {
                result = work()
                semaphore.signal()
            }
            semaphore.wait()
            guard let result else {
                preconditionFailure("Windows main-thread operation completed without a result.")
            }
            return result
        }

        private func enqueue(_ work: @escaping () -> Void) {
            lock.lock()
            workItems.append(work)
            lock.unlock()
            PostThreadMessageW(threadId, adaEngineWorkMessage, 0, 0)
        }

        private func run() {
            threadId = GetCurrentThreadId()
            var bootstrapMessage = MSG()
            PeekMessageW(&bootstrapMessage, nil, 0, 0, UINT(PM_NOREMOVE))
            ready.signal()

            var msg = MSG()
            while GetMessageW(&msg, nil, 0, 0) {
                if msg.message == adaEngineWorkMessage {
                    drainWorkItems()
                } else {
                    TranslateMessage(&msg)
                    DispatchMessageW(&msg)
                }
            }
        }

        private func drainWorkItems() {
            while true {
                lock.lock()
                let items = workItems
                workItems.removeAll(keepingCapacity: true)
                lock.unlock()

                guard !items.isEmpty else {
                    return
                }

                for item in items {
                    item()
                }
            }
        }
    }

    @MainActor
    private func handleMouseButtonDown(
        window: UIWindow,
        button: MouseButton,
        lParam: LPARAM
    ) {
        let windowManager = window.windowManager as? WindowsWindowManager
        guard
            let inputRef = windowManager?.inputRef,
            let systemWindow = window.systemWindow as? WindowsSystemWindow
        else {
            return
        }

        let scaleFactor = getWindowScaleFactor(systemWindow.hwnd)
        let position = logicalMousePosition(
            lParam: lParam,
            hwnd: systemWindow.hwnd,
            scaleFactor: scaleFactor
        )

        unsafe SetCapture(systemWindow.hwnd)

        inputRef.wrappedValue.mousePosition = position
        let modifiers = getWindowsKeyModifiers()
        let isContinious = inputRef.wrappedValue.mouseEvents[button]?.phase == .began

        let mouseEvent = MouseEvent(
            window: window.id,
            button: button,
            mousePosition: position,
            phase: isContinious ? .changed : .began,
            modifierKeys: modifiers,
            time: getCurrentTime()
        )

        inputRef.wrappedValue.receiveEvent(mouseEvent)
    }

    @MainActor
    private func handleMouseButtonUp(
        window: UIWindow,
        button: MouseButton,
        lParam: LPARAM
    ) {
        let windowManager = window.windowManager as? WindowsWindowManager
        guard
            let inputRef = windowManager?.inputRef,
            let systemWindow = window.systemWindow as? WindowsSystemWindow
        else {
            return
        }

        let scaleFactor = getWindowScaleFactor(systemWindow.hwnd)
        let position = logicalMousePosition(
            lParam: lParam,
            hwnd: systemWindow.hwnd,
            scaleFactor: scaleFactor
        )

        unsafe ReleaseCapture()

        inputRef.wrappedValue.mousePosition = position
        let modifiers = getWindowsKeyModifiers()

        let mouseEvent = MouseEvent(
            window: window.id,
            button: button,
            mousePosition: position,
            phase: .ended,
            modifierKeys: modifiers,
            time: getCurrentTime()
        )

        inputRef.wrappedValue.receiveEvent(mouseEvent)
    }

    // MARK: - Windows Window Procedure

    private func WindowsWindowProc(hwnd: HWND?, uMsg: UINT, wParam: WPARAM, lParam: LPARAM) -> LRESULT {
        guard let hwnd = unsafe hwnd else {
            return unsafe DefWindowProcW(hwnd, uMsg, wParam, lParam)
        }

        // Get window from user data
        let windowPtr = unsafe GetWindowLongPtrW(hwnd, GWLP_USERDATA)
        guard windowPtr != 0 else {
            return unsafe DefWindowProcW(hwnd, uMsg, wParam, lParam)
        }

        guard let rawPtr = unsafe UnsafeRawPointer(bitPattern: Int(windowPtr)) else {
            return unsafe DefWindowProcW(hwnd, uMsg, wParam, lParam)
        }
        let window = unsafe Unmanaged<UIWindow>.fromOpaque(rawPtr).takeUnretainedValue()

        switch uMsg {
        case UInt32(WM_GETMINMAXINFO):
            guard let minMaxInfo = unsafe UnsafeMutablePointer<MINMAXINFO>(bitPattern: Int(lParam)) else {
                return unsafe DefWindowProcW(hwnd, uMsg, wParam, lParam)
            }

            let scaleFactor = getWindowScaleFactor(hwnd)
            let minSize = unsafe windowMinimumSizes[window.id] ?? UIWindow.defaultMinimumSize
            let minimumWindowSize = adjustedWindowSize(
                forClientSize: minSize,
                hwnd: hwnd,
                scaleFactor: scaleFactor
            )
            unsafe minMaxInfo.pointee.ptMinTrackSize.x = minimumWindowSize.width
            unsafe minMaxInfo.pointee.ptMinTrackSize.y = minimumWindowSize.height
            return 0

        case UInt32(WM_CLOSE):
            let shouldClose = MainActor.assumeIsolated {
                window.windowShouldClose()
            }
            if shouldClose {
                MainActor.assumeIsolated {
                    window.close()
                }
                return 0
            }
            return 0  // Prevent default window destruction

        case UInt32(WM_DESTROY):
            // Window is being destroyed - clean up resources
            // This can happen if window is destroyed by system or by closeWindow
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                windowManager?.resetTextInputDecoderState(for: window.id)
                // Only remove if not already removed (to avoid double cleanup)
                // This handles the case when window is destroyed by system, not through closeWindow
                if windowManager?.windows[window.id] != nil {
                    // Window was destroyed externally, need to clean up
                    // But don't call DestroyWindow again - it's already destroyed
                    guard let systemWindow = window.systemWindow as? WindowsSystemWindow else {
                        return
                    }
                    unsafe windowMinimumSizes.removeValue(forKey: window.id)

                    // Remove from render engine
                    do {
                        if let renderEngine = unsafe RenderEngine.shared {
                            try renderEngine.destroyWindow(window.id)
                        }
                    } catch {
                        // Ignore errors if window already destroyed
                    }

                    // Clear window handle mapping
                    // windowManager?.windowHandles.removeValue(forKey: window.id)

                    // Set another window as active if needed
                    if let windowManager, !windowManager.windows.isEmpty {
                        if let newWindow = windowManager.windows.values.last?.value {
                            windowManager.setActiveWindow(newWindow)
                        }
                    }
                }
            }
            // Post quit message only if this is the last window
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                if windowManager?.windows.isEmpty == true {
                    PostQuitMessage(0)
                }
            }
            return 0

        case UInt32(WM_NCDESTROY):
            // Non-client area destroyed - final cleanup
            // Clear window handle from mapping
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                if let systemWindow = window.systemWindow as? WindowsSystemWindow {
                    // windowManager?.windowHandles.removeValue(forKey: window.id)
                }
            }
            return unsafe DefWindowProcW(hwnd, uMsg, wParam, lParam)

        case UInt32(WM_SIZE):
            guard wParam != WPARAM(SIZE_MINIMIZED) else {
                return 0
            }

            let width = UInt16(truncatingIfNeeded: lParam & 0xFFFF)
            let height = UInt16(truncatingIfNeeded: (lParam >> 16) & 0xFFFF)
            guard width > 0 && height > 0 else {
                return 0
            }

            let scaleFactor = getWindowScaleFactor(hwnd)
            let sizeInt = logicalSize(
                fromPhysicalWidth: width,
                height: height,
                scaleFactor: scaleFactor
            )

            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                windowManager?
                    .synchronizeRenderMetrics(
                        for: window,
                        sizeInt: sizeInt,
                        scaleFactor: scaleFactor,
                        updateWindowFrame: true
                    )
            }
            return 0

        case UInt32(WM_EXITSIZEMOVE):
            let scaleFactor = getWindowScaleFactor(hwnd)
            var clientRect = RECT()
            unsafe GetClientRect(hwnd, &clientRect)
            let width = UInt16(truncatingIfNeeded: clientRect.right - clientRect.left)
            let height = UInt16(truncatingIfNeeded: clientRect.bottom - clientRect.top)
            guard width > 0 && height > 0 else {
                return 0
            }

            let sizeInt = logicalSize(
                fromPhysicalWidth: width,
                height: height,
                scaleFactor: scaleFactor
            )

            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                windowManager?
                    .synchronizeRenderMetrics(
                        for: window,
                        sizeInt: sizeInt,
                        scaleFactor: scaleFactor,
                        updateWindowFrame: true
                    )
                windowManager?.setActiveWindow(window)
            }
            return 0

        case UInt32(WM_DPICHANGED):
            let dpi = UInt32(wParam & 0xFFFF)
            let scaleFactor = max(Float(dpi) / 96.0, 1)

            if let suggestedRect = unsafe UnsafePointer<RECT>(bitPattern: Int(lParam)) {
                unsafe SetWindowPos(
                    hwnd,
                    nil,
                    suggestedRect.pointee.left,
                    suggestedRect.pointee.top,
                    suggestedRect.pointee.right - suggestedRect.pointee.left,
                    suggestedRect.pointee.bottom - suggestedRect.pointee.top,
                    UINT(SWP_NOZORDER | SWP_NOACTIVATE)
                )
            }

            var clientRect = RECT()
            unsafe GetClientRect(hwnd, &clientRect)
            let sizeInt = logicalSize(
                fromPhysicalWidth: UInt16(truncatingIfNeeded: clientRect.right - clientRect.left),
                height: UInt16(truncatingIfNeeded: clientRect.bottom - clientRect.top),
                scaleFactor: scaleFactor
            )
            let newSize = sizeInt.toSize()

            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                windowManager?
                    .synchronizeRenderMetrics(
                        for: window,
                        sizeInt: sizeInt,
                        scaleFactor: scaleFactor,
                        updateWindowFrame: window.frame.size != newSize
                    )
            }
            return 0

        case UInt32(WM_SETFOCUS):
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                windowManager?.setActiveWindow(window)
            }
            return 0

        case UInt32(WM_KILLFOCUS):
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                windowManager?.resetTextInputDecoderState(for: window.id)
                windowManager?.resignActiveWindow(window)
            }
            return 0

        case UInt32(WM_KEYDOWN),
            UInt32(WM_SYSKEYDOWN):
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                guard let inputRef = windowManager?.inputRef else {
                    return
                }

                let vkCode = UInt16(wParam & 0xFF)
                let keyCode = translateWindowsKeyCode(vkCode: vkCode)
                let modifiers = getWindowsKeyModifiers()
                let isRepeated = (lParam & 0x4000_0000) != 0

                let keyEvent = KeyEvent(
                    window: window.id,
                    keyCode: keyCode,
                    modifiers: modifiers,
                    status: .down,
                    time: getCurrentTime(),
                    isRepeated: isRepeated
                )

                inputRef.wrappedValue.receiveEvent(keyEvent)
            }
            return 0

        case UInt32(WM_KEYUP),
            UInt32(WM_SYSKEYUP):
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                guard let inputRef = windowManager?.inputRef else {
                    return
                }

                let vkCode = UInt16(wParam & 0xFF)
                let keyCode = translateWindowsKeyCode(vkCode: vkCode)
                let modifiers = getWindowsKeyModifiers()

                let keyEvent = KeyEvent(
                    window: window.id,
                    keyCode: keyCode,
                    modifiers: modifiers,
                    status: .up,
                    time: getCurrentTime(),
                    isRepeated: false
                )

                inputRef.wrappedValue.receiveEvent(keyEvent)
            }
            return 0

        case UInt32(WM_CHAR),
            UInt32(WM_SYSCHAR):
            Task { @MainActor in
                guard
                    let windowManager = window.windowManager as? WindowsWindowManager,
                    let inputRef = windowManager.inputRef
                else {
                    return
                }

                let codeUnit = UInt16(truncatingIfNeeded: wParam & 0xFFFF)

                if codeUnit == 0x08 {
                    windowManager.resetTextInputDecoderState(for: window.id)
                    let textEvent = TextInputEvent(
                        window: window.id,
                        text: "",
                        action: .deleteBackward,
                        time: getCurrentTime()
                    )
                    inputRef.wrappedValue.receiveEvent(textEvent)
                    return
                }

                guard let scalar = windowManager.decodeTextInputScalar(from: codeUnit, for: window.id) else {
                    return
                }

                let character = String(scalar)
                let sanitizedText =
                    character
                    .replacingOccurrences(of: "\r\n", with: " ")
                    .replacingOccurrences(of: "\n", with: " ")
                    .replacingOccurrences(of: "\r", with: " ")

                guard !sanitizedText.isEmpty else {
                    return
                }

                let hasPrintableScalar = sanitizedText.unicodeScalars.contains { value in
                    value.value >= 0x20 && value.value != 0x7F
                }

                guard hasPrintableScalar else {
                    return
                }

                let textEvent = TextInputEvent(
                    window: window.id,
                    text: sanitizedText,
                    action: .insert,
                    time: getCurrentTime()
                )

                inputRef.wrappedValue.receiveEvent(textEvent)
            }
            return 0

        case UInt32(WM_MOUSEMOVE):
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                guard
                    let inputRef = windowManager?.inputRef,
                    let systemWindow = window.systemWindow as? WindowsSystemWindow
                else {
                    return
                }

                let scaleFactor = getWindowScaleFactor(systemWindow.hwnd)
                let position = logicalMousePosition(
                    lParam: lParam,
                    hwnd: systemWindow.hwnd,
                    scaleFactor: scaleFactor
                )

                inputRef.wrappedValue.mousePosition = position
                let modifiers = getWindowsKeyModifiers()
                let mouseButton: MouseButton = (wParam & 0x0001) != 0 ? .left : .none

                let mouseEvent = MouseEvent(
                    window: window.id,
                    button: mouseButton,
                    mousePosition: position,
                    phase: .changed,
                    modifierKeys: modifiers,
                    time: getCurrentTime()
                )

                inputRef.wrappedValue.receiveEvent(mouseEvent)
            }
            return 0

        case UInt32(WM_LBUTTONDOWN):
            Task { @MainActor in
                handleMouseButtonDown(
                    window: window,
                    button: .left,
                    lParam: lParam
                )
            }
            return 0

        case UInt32(WM_LBUTTONUP):
            Task { @MainActor in
                handleMouseButtonUp(
                    window: window,
                    button: .left,
                    lParam: lParam
                )
            }
            return 0

        case UInt32(WM_RBUTTONDOWN):
            Task { @MainActor in
                handleMouseButtonDown(
                    window: window,
                    button: .right,
                    lParam: lParam
                )
            }
            return 0

        case UInt32(WM_RBUTTONUP):
            Task { @MainActor in
                handleMouseButtonUp(
                    window: window,
                    button: .right,
                    lParam: lParam
                )
            }
            return 0

        case UInt32(WM_MBUTTONDOWN):
            Task { @MainActor in
                handleMouseButtonDown(
                    window: window,
                    button: .middle,
                    lParam: lParam
                )
            }
            return 0

        case UInt32(WM_MBUTTONUP):
            Task { @MainActor in
                handleMouseButtonUp(
                    window: window,
                    button: .middle,
                    lParam: lParam
                )
            }
            return 0

        case UInt32(WM_MOUSEWHEEL):
            Task { @MainActor in
                let windowManager = window.windowManager as? WindowsWindowManager
                guard
                    let inputRef = windowManager?.inputRef,
                    let systemWindow = window.systemWindow as? WindowsSystemWindow
                else {
                    return
                }

                let delta = Int16(truncatingIfNeeded: (wParam >> 16) & 0xFFFF)
                let scrollDelta = Point(x: 0, y: Float(delta) / 120.0)

                let scaleFactor = getWindowScaleFactor(systemWindow.hwnd)
                let position = logicalMousePosition(
                    lParam: lParam,
                    hwnd: systemWindow.hwnd,
                    scaleFactor: scaleFactor,
                    isScreenPosition: true
                )

                let modifiers = getWindowsKeyModifiers()

                let mouseEvent = MouseEvent(
                    window: window.id,
                    button: .scrollWheel,
                    scrollDelta: scrollDelta,
                    mousePosition: position,
                    phase: .changed,
                    modifierKeys: modifiers,
                    time: getCurrentTime()
                )

                inputRef.wrappedValue.receiveEvent(mouseEvent)
            }
            return 0

        default:
            return unsafe DefWindowProcW(hwnd, uMsg, wParam, lParam)
        }
    }

    // MARK: - WindowsSystemWindow
    @safe
    final class WindowsSystemWindow: SystemWindow {
        let hwnd: HWND
        let surface: WindowsSurface

        init(hwnd: HWND, surface: WindowsSurface) {
            unsafe self.hwnd = unsafe hwnd
            self.surface = surface
        }

        var title: String {
            get {
                var buffer = [WCHAR](repeating: 0, count: 256)
                unsafe GetWindowTextW(hwnd, &buffer, 256)
                return String(decodingCString: buffer, as: UTF16.self)
            }
            set {
                unsafe SetWindowTextW(hwnd, newValue.wide)
            }
        }

        var size: Size {
            get {
                let scaleFactor = getWindowScaleFactor(hwnd)
                var rect = RECT()
                unsafe GetClientRect(hwnd, &rect)
                return Size(
                    width: Float(rect.right - rect.left) / scaleFactor,
                    height: Float(rect.bottom - rect.top) / scaleFactor
                )
            }
            set {
                let scaleFactor = getWindowScaleFactor(hwnd)
                let dpi = UINT(max((scaleFactor * 96).rounded(), 96))
                let style = DWORD(WS_OVERLAPPEDWINDOW)
                var rect = RECT(
                    left: 0,
                    top: 0,
                    right: LONG((newValue.width * scaleFactor).rounded()),
                    bottom: LONG((newValue.height * scaleFactor).rounded())
                )
                unsafe AdjustWindowRectExForDpi(&rect, style, false, 0, dpi)
                unsafe SetWindowPos(hwnd, nil, 0, 0, rect.right - rect.left, rect.bottom - rect.top, UINT(SWP_NOMOVE | SWP_NOZORDER))
            }
        }

        var position: Point {
            get {
                var rect = RECT()
                unsafe GetWindowRect(hwnd, &rect)
                return Point(x: Float(rect.left), y: Float(rect.top))
            }
            set {
                unsafe SetWindowPos(hwnd, nil, LONG(newValue.x), LONG(newValue.y), 0, 0, UINT(SWP_NOSIZE | SWP_NOZORDER))
            }
        }
    }

    // MARK: - WindowsScreenManager

    final class WindowsScreenManager: ScreenManager {
        func getMainScreen() -> Screen? {
            guard let hMonitor = unsafe MonitorFromWindow(nil, UInt32(MONITOR_DEFAULTTOPRIMARY)) else {
                return nil
            }
            return unsafe makeScreen(from: hMonitor)
        }

        func getScreens() -> [Screen] {
            final class ScreensCollector: @unchecked Sendable {
                var screens: [Screen] = []
            }

            let collector = ScreensCollector()
            let collectorPtr = unsafe Unmanaged.passUnretained(collector).toOpaque()

            unsafe EnumDisplayMonitors(
                nil,
                nil,
                { hMonitor, _, _, lParam in
                    guard let hMonitor = unsafe hMonitor, lParam != 0 else {
                        return WindowsBool(true)
                    }
                    guard let collectorPointer = UnsafeRawPointer(bitPattern: Int(lParam)) else {
                        return WindowsBool(true)
                    }
                    let collector = unsafe Unmanaged<ScreensCollector>.fromOpaque(collectorPointer).takeUnretainedValue()
                    if let screen = unsafe Self.shared?.makeScreen(from: hMonitor) {
                        collector.screens.append(screen)
                    }
                    return WindowsBool(true)
                },
                LPARAM(Int(bitPattern: collectorPtr))
            )

            return collector.screens
        }

        func getScreenScale(for screen: Screen) -> Float {
            guard let windowsScreen = screen.systemScreen as? WindowsSystemScreen else {
                return 1.0
            }
            let hMonitor = unsafe windowsScreen.hMonitor

            var info = MONITORINFO()
            info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)

            if unsafe GetMonitorInfoW(hMonitor, &info) {
                // Get DPI for the monitor
                var dpiX: UINT = 0
                var dpiY: UINT = 0
                unsafe GetDpiForMonitor(hMonitor, MDT_EFFECTIVE_DPI, &dpiX, &dpiY)
                return Float(dpiX) / 96.0  // 96 DPI is standard
            }

            return 1.0
        }

        func getSize(for screen: Screen) -> Size {
            guard let windowsScreen = screen.systemScreen as? WindowsSystemScreen else {
                return .zero
            }
            let hMonitor = unsafe windowsScreen.hMonitor

            var info = MONITORINFO()
            info.cbSize = DWORD(MemoryLayout<MONITORINFO>.size)

            if unsafe GetMonitorInfoW(hMonitor, &info) {
                let width = Float(info.rcMonitor.right - info.rcMonitor.left)
                let height = Float(info.rcMonitor.bottom - info.rcMonitor.top)
                return Size(width: width, height: height)
            }

            return .zero
        }

        func getBrightness(for _: Screen) -> Float {
            // Windows brightness API is complex, return default for now
            return 1.0
        }

        func makeScreen(from systemScreen: SystemScreen) -> Screen {
            return Screen(systemScreen: systemScreen, screenManager: self)
        }

        func makeScreen(from hMonitor: HMONITOR) -> Screen? {
            let systemScreen = WindowsSystemScreen(hMonitor: hMonitor)
            return makeScreen(from: systemScreen)
        }

        nonisolated(unsafe) static var shared: WindowsScreenManager?
    }

    /// Wrapper class for HMONITOR to conform to SystemScreen protocol
    @safe
    final class WindowsSystemScreen: SystemScreen {
        let hMonitor: HMONITOR

        @safe init(hMonitor: HMONITOR) {
            unsafe self.hMonitor = hMonitor
        }
    }

    extension String {
        var wide: [WCHAR] {
            return self.utf8.map { WCHAR($0) } + [0]
        }
    }

#endif
