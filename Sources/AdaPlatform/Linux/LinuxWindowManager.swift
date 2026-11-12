#if os(Linux)
    @_spi(Internal) import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import Foundation
    import Logging
    import Math
    import X11

    @MainActor
    final class LinuxWindowManager: UIWindowManager {
        let display: LinuxDisplay
        private var nativeWindows: [UIWindow.ID: LinuxSystemWindow] = [:]
        private var windowIDs: [X11.Window: UIWindow.ID] = [:]
        private var renderedSizes: [UIWindow.ID: Size] = [:]
        private var synchronizingWindows: Set<UIWindow.ID> = []
        private var cursorShape: Input.CursorShape = .arrow
        private var mouseMode: Input.MouseMode = .visible
        private var cursor: X11.Cursor = 0
        private let deleteWindow: Atom
        private let protocols: Atom
        private let input = LinuxInput()

        init(display: LinuxDisplay) {
            self.display = display
            deleteWindow = unsafe XInternAtom(display.pointer, "WM_DELETE_WINDOW", 0)
            protocols = unsafe XInternAtom(display.pointer, "WM_PROTOCOLS", 0)
            super.init()
        }

        isolated deinit {
            if cursor != 0 { unsafe XFreeCursor(display.pointer, cursor) }
        }

        override func createWindow(for window: UIWindow) {
            let minimum = window.configuration.minimumSize
            let size = Size(width: max(window.frame.width, minimum.width, 1), height: max(window.frame.height, minimum.height, 1))
            let handle = unsafe XCreateSimpleWindow(
                display.pointer,
                XDefaultRootWindow(display.pointer),
                Int32(window.frame.origin.x),
                Int32(window.frame.origin.y),
                UInt32(size.width),
                UInt32(size.height),
                0,
                0,
                0
            )
            guard handle != 0 else {
                Logger(label: "org.adaengine.linux").error("Cannot create X11 window")
                return
            }
            let native = LinuxSystemWindow(display: display, handle: handle)
            nativeWindows[window.id] = native
            windowIDs[handle] = window.id
            native.title = window.configuration.title ?? "AdaEngine"
            unsafe ada_x11_set_decorated(display.pointer, handle, window.configuration.chrome == .borderless ? 0 : 1)
            native.onClose = { [weak self, weak window] in
                if let window { self?.closeWindow(window) }
            }
            unsafe XSelectInput(
                display.pointer,
                handle,
                KeyPressMask | KeyReleaseMask | ButtonPressMask | ButtonReleaseMask
                    | PointerMotionMask | FocusChangeMask | StructureNotifyMask | ExposureMask | EnterWindowMask | LeaveWindowMask
            )
            var closeAtom = deleteWindow
            unsafe XSetWMProtocols(display.pointer, handle, &closeAtom, 1)
            setMinimumSize(minimum, for: window)
            synchronizingWindows.insert(window.id)
            window.frame = Rect(origin: .zero, size: size)
            synchronizingWindows.remove(window.id)
            window.systemWindow = native
            do {
                guard let renderer = unsafe RenderEngine.shared else {
                    throw LinuxWindowError.rendererUnavailable
                }
                try renderer.createWindow(window.id, for: native, size: size.toSizeInt())
                renderedSizes[window.id] = size
            } catch {
                Logger(label: "org.adaengine.linux").error("Cannot create render window: \(error)")
                windowIDs[handle] = nil
                nativeWindows[window.id] = nil
                window.systemWindow = nil
                native.destroy()
                return
            }
            super.createWindow(for: window)
            setWindowMode(window, mode: window.configuration.mode)
        }

        override func showWindow(_ window: UIWindow, isFocused: Bool) {
            guard let native = nativeWindows[window.id] else {
                return
            }
            unsafe XMapWindow(display.pointer, native.handle)
            if isFocused {
                unsafe XRaiseWindow(display.pointer, native.handle)
                unsafe XFlush(display.pointer)
                // Focus is assigned by the window manager when MapNotify/FocusIn arrive.
                setActiveWindow(window)
            }
            unsafe XFlush(display.pointer)
            window.windowDidAppear()
        }

        override func closeWindow(_ window: UIWindow) {
            guard window.windowShouldClose(), let native = nativeWindows[window.id] else {
                return
            }
            input.releaseAll(for: window, inputRef: inputRef)
            resignActiveWindow(window)
            removeWindow(window)
            // Destroy GPU resources before the Xlib window and its input context.
            guard windows[window.id] == nil else {
                return
            }
            windowIDs[native.handle] = nil
            nativeWindows[window.id] = nil
            renderedSizes[window.id] = nil
            window.systemWindow = nil
            if unsafe RenderEngine.shared?.type != .saga {
                native.destroy()
            }
            unsafe XFlush(display.pointer)
        }

        override func resizeWindow(_ window: UIWindow, size: Size) {
            guard !synchronizingWindows.contains(window.id), let native = nativeWindows[window.id] else {
                return
            }
            native.size = size
        }

        override func setMinimumSize(_ size: Size, for window: UIWindow) {
            guard let native = nativeWindows[window.id] else {
                return
            }
            var hints = XSizeHints()
            hints.flags = Int(PMinSize)
            hints.min_width = Int32(max(size.width, 1))
            hints.min_height = Int32(max(size.height, 1))
            if !window.configuration.isResizable {
                hints.flags |= Int(PMaxSize)
                hints.min_width = Int32(max(window.frame.width, size.width, 1))
                hints.min_height = Int32(max(window.frame.height, size.height, 1))
                hints.max_width = hints.min_width
                hints.max_height = hints.min_height
            }
            unsafe XSetWMNormalHints(display.pointer, native.handle, &hints)
        }

        override func setWindowMode(_ window: UIWindow, mode: UIWindow.Mode) {
            guard let native = nativeWindows[window.id] else {
                return
            }
            var attributes = XWindowAttributes()
            unsafe XGetWindowAttributes(display.pointer, native.handle, &attributes)
            if attributes.map_state == IsUnmapped {
                let property = unsafe XInternAtom(display.pointer, "_NET_WM_STATE", 0)
                var fullscreen = unsafe XInternAtom(display.pointer, "_NET_WM_STATE_FULLSCREEN", 0)
                unsafe withUnsafePointer(to: &fullscreen) { pointer in
                    unsafe XChangeProperty(
                        display.pointer,
                        native.handle,
                        property,
                        Atom(XA_ATOM),
                        32,
                        PropModeReplace,
                        UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self),
                        mode == .windowed ? 0 : 1
                    )
                }
                return
            }
            var event = XEvent()
            event.xclient.type = ClientMessage
            event.xclient.window = native.handle
            event.xclient.message_type = unsafe XInternAtom(display.pointer, "_NET_WM_STATE", 0)
            event.xclient.format = 32
            event.xclient.data.l.0 = mode == .windowed ? 0 : 1
            event.xclient.data.l.1 = unsafe Int(XInternAtom(display.pointer, "_NET_WM_STATE_FULLSCREEN", 0))
            event.xclient.data.l.3 = 1
            unsafe XSendEvent(display.pointer, XDefaultRootWindow(display.pointer), 0, SubstructureRedirectMask | SubstructureNotifyMask, &event)
            unsafe XFlush(display.pointer)
        }

        func pollEvents() {
            // Bound each batch so a busy pointer or another X11 client cannot starve frame updates.
            for _ in 0..<1024 {
                guard unsafe XPending(display.pointer) > 0 else {
                    break
                }
                var event = XEvent()
                unsafe XNextEvent(display.pointer, &event)
                if event.type == MappingNotify {
                    unsafe XRefreshKeyboardMapping(&event.xmapping)
                    continue
                }
                guard unsafe XFilterEvent(&event, 0) == 0,
                    let id = windowIDs[event.xany.window], let window = windows[id], let native = nativeWindows[id]
                else {
                    continue
                }
                switch event.type {
                case ClientMessage:
                    if event.xclient.message_type == protocols, event.xclient.format == 32, event.xclient.data.l.0 == Int(deleteWindow) {
                        closeWindow(window)
                    }
                case ConfigureNotify:
                    let size = Size(width: Float(event.xconfigure.width), height: Float(event.xconfigure.height))
                    guard size.width > 0, size.height > 0, renderedSizes[id] != size else {
                        continue
                    }
                    synchronizingWindows.insert(id)
                    window.frame.size = size
                    synchronizingWindows.remove(id)
                    window.setNeedsLayout()
                    do {
                        unsafe try RenderEngine.shared.resizeWindow(id, newSize: size.toSizeInt(), scaleFactor: 1)
                        renderedSizes[id] = size
                    } catch {
                        Logger(label: "org.adaengine.linux").error("Cannot resize render window: \(error)")
                    }
                case FocusIn:
                    setActiveWindow(window)
                    if let context = native.inputContext { unsafe XSetICFocus(context) }
                    applyMouseMode()
                case FocusOut:
                    if let context = native.inputContext { unsafe XUnsetICFocus(context) }
                    input.releaseAll(for: window, inputRef: inputRef)
                    unsafe XUngrabPointer(display.pointer, UInt(CurrentTime))
                    resignActiveWindow(window)
                case MapNotify: window.canDraw = true
                case UnmapNotify: window.canDraw = false
                default: input.receive(&event, for: window, native: native, inputRef: inputRef)
                }
            }
        }

        override func setCursorShape(_ shape: Input.CursorShape) {
            guard cursorShape != shape || cursor == 0 else {
                return
            }
            cursorShape = shape
            if cursor != 0 { unsafe XFreeCursor(display.pointer, cursor) }
            cursor = unsafe XCreateFontCursor(display.pointer, LinuxInput.cursorFont(for: cursorShape))
            updateCursor()
        }
        override func getCursorShape() -> Input.CursorShape { cursorShape }
        override func setCursorImage(for _: Input.CursorShape, texture _: Texture2D?, hotspot _: Vector2) {}
        override func setMouseMode(_ mode: Input.MouseMode) {
            mouseMode = mode
            applyMouseMode()
        }
        override func getMouseMode() -> Input.MouseMode { mouseMode }

        override func updateCursor() {
            guard mouseMode == .visible || mouseMode == .confined else {
                return
            }
            if cursor == 0 { cursor = unsafe XCreateFontCursor(display.pointer, LinuxInput.cursorFont(for: cursorShape)) }
            for native in nativeWindows.values { unsafe XDefineCursor(display.pointer, native.handle, cursor) }
            unsafe XFlush(display.pointer)
        }

        private func applyMouseMode() {
            unsafe XUngrabPointer(display.pointer, UInt(CurrentTime))
            guard let window = activeWindow, let native = nativeWindows[window.id] else {
                return
            }
            if mouseMode == .captured || mouseMode == .confined || mouseMode == .confinedHidden {
                unsafe XGrabPointer(
                    display.pointer,
                    native.handle,
                    1,
                    UInt32(ButtonPressMask | ButtonReleaseMask | PointerMotionMask),
                    GrabModeAsync,
                    GrabModeAsync,
                    native.handle,
                    0,
                    UInt(CurrentTime)
                )
            }
            // Cursor visibility is provided by a transparent native bitmap.
            if mouseMode == .hidden || mouseMode == .confinedHidden || mouseMode == .captured {
                var bits: CChar = 0
                let bitmap = unsafe XCreateBitmapFromData(display.pointer, native.handle, &bits, 1, 1)
                var color = XColor()
                var background = XColor()
                let hidden = unsafe XCreatePixmapCursor(display.pointer, bitmap, bitmap, &color, &background, 0, 0)
                unsafe XDefineCursor(display.pointer, native.handle, hidden)
                unsafe XFreeCursor(display.pointer, hidden)
                unsafe XFreePixmap(display.pointer, bitmap)
            } else {
                updateCursor()
            }
            unsafe XFlush(display.pointer)
        }
    }

    private enum LinuxWindowError: Error { case rendererUnavailable }
#endif
