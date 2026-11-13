#if os(Linux)
    import AdaRender
    @_spi(Internal) import AdaUI
    import Math
    import X11

    @MainActor
    final class LinuxSystemWindow: SystemWindow, LinuxXlibRenderSurface {
        let display: LinuxDisplay
        private(set) var handle: X11.Window
        private(set) var inputContext: XIC?
        private var storedTitle = "AdaEngine"
        var onClose: (() -> Void)?

        init(display: LinuxDisplay, handle: X11.Window) {
            self.display = display
            self.handle = handle
            if let method = display.inputMethod {
                inputContext = unsafe ada_x11_create_input_context(method, handle)
            }
        }

        isolated deinit {
            if let inputContext { unsafe XDestroyIC(inputContext) }
            if handle != 0 { unsafe XDestroyWindow(display.pointer, handle) }
        }

        func destroy() {
            if let inputContext { unsafe XDestroyIC(inputContext) }
            inputContext = nil
            if handle != 0 { unsafe XDestroyWindow(display.pointer, handle) }
            handle = 0
        }

        var xlibDisplay: UnsafeMutableRawPointer { unsafe UnsafeMutableRawPointer(display.pointer) }
        var xlibWindow: UInt64 { UInt64(handle) }
        var xlibWindowLifetime: any Sendable { self }
        var scaleFactor: Float { 1 }
        var prefferedPixelFormat: PixelFormat { .bgra8 }

        func performCaptionAction(_ action: WindowCaptionAction) {
            switch action {
            case .minimize:
                unsafe XIconifyWindow(display.pointer, handle, XDefaultScreen(display.pointer))
            case .close: onClose?()
            case .toggleMaximize:
                var event = XEvent()
                event.xclient.type = ClientMessage
                event.xclient.window = handle
                event.xclient.message_type = unsafe XInternAtom(display.pointer, "_NET_WM_STATE", 0)
                event.xclient.format = 32
                event.xclient.data.l.0 = 2
                event.xclient.data.l.1 = unsafe Int(XInternAtom(display.pointer, "_NET_WM_STATE_MAXIMIZED_VERT", 0))
                event.xclient.data.l.2 = unsafe Int(XInternAtom(display.pointer, "_NET_WM_STATE_MAXIMIZED_HORZ", 0))
                event.xclient.data.l.3 = 1
                unsafe XSendEvent(display.pointer, XDefaultRootWindow(display.pointer), 0, SubstructureRedirectMask | SubstructureNotifyMask, &event)
            }
            unsafe XFlush(display.pointer)
        }

        var title: String {
            get { storedTitle }
            set {
                storedTitle = newValue
                unsafe XStoreName(display.pointer, handle, newValue)
                let property = unsafe XInternAtom(display.pointer, "_NET_WM_NAME", 0)
                let utf8 = unsafe XInternAtom(display.pointer, "UTF8_STRING", 0)
                let bytes = Array(newValue.utf8)
                unsafe bytes.withUnsafeBufferPointer { buffer in
                    unsafe XChangeProperty(display.pointer, handle, property, utf8, 8, PropModeReplace, buffer.baseAddress, Int32(buffer.count))
                }
                unsafe XFlush(display.pointer)
            }
        }

        var size: Size {
            get {
                var attributes = XWindowAttributes()
                unsafe XGetWindowAttributes(display.pointer, handle, &attributes)
                return Size(width: Float(attributes.width), height: Float(attributes.height))
            }
            set {
                unsafe XResizeWindow(display.pointer, handle, UInt32(max(newValue.width, 1)), UInt32(max(newValue.height, 1)))
                unsafe XFlush(display.pointer)
            }
        }

        var position: Point {
            get {
                var x: Int32 = 0
                var y: Int32 = 0
                var child: X11.Window = 0
                unsafe XTranslateCoordinates(display.pointer, handle, XDefaultRootWindow(display.pointer), 0, 0, &x, &y, &child)
                return Point(x: Float(x), y: Float(y))
            }
            set {
                unsafe XMoveWindow(display.pointer, handle, Int32(newValue.x), Int32(newValue.y))
                unsafe XFlush(display.pointer)
            }
        }
    }
#endif
