#if os(Android)
    @_spi(Internal) import AdaInput
    import AdaRender
    @_spi(Internal) import AdaUI
    import AdaUtils
    import CAndroid
    import Foundation
    import Logging
    import Math

    @MainActor
    final class AndroidWindowManager: UIWindowManager {
        private var surfaces: [UIWindow.ID: AndroidRenderSurface] = [:]

        override func createWindow(for window: UIWindow) {
            guard windows.isEmpty else {
                Logger(label: "org.adaengine.android").error("Android NativeActivity supports one window per activity")
                return
            }
            guard let surface = AndroidRenderSurface() else { return }
            surfaces[window.id] = surface
            window.frame = Rect(origin: .zero, size: surface.logicalSize)
            window.systemWindow = AndroidSystemWindow(size: surface.logicalSize)
            do {
                unsafe try RenderEngine.shared.createWindow(window.id, for: surface, size: surface.logicalSize.toSizeInt())
            } catch {
                Logger(label: "org.adaengine.android").error("Cannot create Android render window: \(error)")
                unsafe ada_android_finish()
                return
            }
            super.createWindow(for: window)
        }

        func surfaceLost() {
            for id in surfaces.keys {
                unsafe try? RenderEngine.shared.destroyWindow(id)
            }
            surfaces.removeAll()
        }

        func surfaceChanged() {
            for (id, window) in windows.values where surfaces[id] == nil {
                guard let surface = AndroidRenderSurface() else { continue }
                surfaces[id] = surface
                unsafe try? RenderEngine.shared.createWindow(id, for: surface, size: surface.logicalSize.toSizeInt())
                window.frame.size = surface.logicalSize
            }
            for (id, surface) in surfaces {
                guard let window = windows[id] else { continue }
                if window.frame.size != surface.logicalSize { window.frame.size = surface.logicalSize }
                window.systemWindow?.size = surface.logicalSize
                do {
                    unsafe try RenderEngine.shared.resizeWindow(id, newSize: surface.logicalSize.toSizeInt(), scaleFactor: surface.scaleFactor)
                } catch {
                    Logger(label: "org.adaengine.android").error("Cannot resize Android render window: \(error)")
                }
            }
        }

        override func showWindow(_ window: UIWindow, isFocused: Bool) {
            if isFocused { setActiveWindow(window) }
            window.windowDidAppear()
        }
        override func closeWindow(_ window: UIWindow) {
            guard window.windowShouldClose() else { return }
            surfaces[window.id] = nil
            removeWindow(window)
            unsafe ada_android_finish()
        }
        override func resizeWindow(_: UIWindow, size _: Size) { surfaceChanged() }
        override func setMinimumSize(_: Size, for _: UIWindow) {}
        override func setWindowMode(_: UIWindow, mode _: UIWindow.Mode) {}
        override func setCursorShape(_: Input.CursorShape) {}
        override func getCursorShape() -> Input.CursorShape { .arrow }
        override func setCursorImage(for _: Input.CursorShape, texture _: Texture2D?, hotspot _: Vector2) {}
        override func setMouseMode(_: Input.MouseMode) {}
        override func getMouseMode() -> Input.MouseMode { .visible }
        override func updateCursor() {}
    }

    @MainActor
    private final class AndroidSystemWindow: SystemWindow {
        var title = "AdaEngine"
        var size: Size
        var position: Point = .zero
        init(size: Size) { self.size = size }
    }

    // The native handle is immutable and ANativeWindow acquire/release are
    // thread-safe. The lease can outlive its main-actor surface in a GPU job.
    private final class AndroidNativeWindowLease: @unchecked Sendable {
        let pointer: UnsafeMutableRawPointer
        init?() {
            guard let pointer = unsafe ada_android_acquire_window() else { return nil }
            unsafe self.pointer = pointer
        }
        deinit { unsafe ada_android_release_window(pointer) }
    }

    @MainActor
    final class AndroidRenderSurface: AndroidNativeWindowRenderSurface {
        private let lease: AndroidNativeWindowLease
        var nativeWindow: UnsafeMutableRawPointer { unsafe lease.pointer }
        init?() {
            guard let lease = AndroidNativeWindowLease() else { return nil }
            self.lease = lease
        }
        var scaleFactor: Float { max(unsafe ada_android_scale(), 1) }
        var prefferedPixelFormat: PixelFormat { .rgba8 }
        var logicalSize: Size {
            Size(width: Float(unsafe ada_android_width()) / scaleFactor, height: Float(unsafe ada_android_height()) / scaleFactor)
        }
    }
#endif
