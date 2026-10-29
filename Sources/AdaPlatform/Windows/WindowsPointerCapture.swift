#if os(Windows)
import AdaInput
import Math
import Synchronization
import WinSDK

/// Native operations run on the HWND thread. The mutex also lets the render
/// thread query the acknowledged mode without touching Win32 window state.
enum WindowsPointerCapture {
    private struct State: Sendable {
        var window: UInt = 0
        var mode: Input.MouseMode = .visible
        var restoreX: LONG = 0
        var restoreY: LONG = 0
    }
    private static let state = Mutex(State())

    static var mode: Input.MouseMode { state.withLock { $0.mode } }

    static func isHidden(in window: HWND) -> Bool {
        state.withLock { $0.window == UInt(bitPattern: window) && ($0.mode == .captured || $0.mode == .hidden || $0.mode == .confinedHidden) }
    }

    static func setMode(_ mode: Input.MouseMode, window: HWND?) {
        release()
        guard mode != .visible, let window, GetForegroundWindow() == window else { return }
        var position = POINT()
        guard GetCursorPos(&position) else { return }
        var rect = RECT()
        guard GetClientRect(window, &rect), rect.right > 0, rect.bottom > 0 else { return }
        var origin = POINT(x: 0, y: 0)
        guard ClientToScreen(window, &origin) else { return }
        rect.left += origin.x; rect.right += origin.x
        rect.top += origin.y; rect.bottom += origin.y
        if mode == .captured || mode == .confined || mode == .confinedHidden {
            guard ClipCursor(&rect) else { return }
        }
        state.withLock {
            $0 = State(window: UInt(bitPattern: window), mode: mode, restoreX: position.x, restoreY: position.y)
        }
        if mode == .captured {
            SetCursorPos((rect.left + rect.right) / 2, (rect.top + rect.bottom) / 2)
        }
        if isHidden(in: window) { SetCursor(nil) }
    }

    static func release(window: HWND? = nil) {
        let previous = state.withLock { value -> State? in
            guard value.window != 0, window == nil || value.window == UInt(bitPattern: window!) else { return nil }
            let previous = value
            value = State()
            return previous
        }
        guard let previous else { return }
        ClipCursor(nil)
        if previous.mode == .captured { SetCursorPos(previous.restoreX, previous.restoreY) }
    }

    /// Recenter before dispatching to the main actor, so queued events cannot
    /// mistake the synthetic warp for camera movement or hit a screen edge.
    static func motion(window: HWND, lParam: LPARAM, scale: Float) -> (Point, Vector2)? {
        guard state.withLock({ $0.window == UInt(bitPattern: window) && $0.mode == .captured }) else { return nil }
        var rect = RECT()
        guard GetClientRect(window, &rect) else { return nil }
        let x = (rect.right - rect.left) / 2
        let y = (rect.bottom - rect.top) / 2
        let dx = LONG(Int16(truncatingIfNeeded: lParam)) - x
        let dy = LONG(Int16(truncatingIfNeeded: lParam >> 16)) - y
        if dx != 0 || dy != 0 {
            var center = POINT(x: x, y: y)
            if ClientToScreen(window, &center) { SetCursorPos(center.x, center.y) }
        }
        return (Point(x: Float(x) / scale, y: Float(y) / scale), Vector2(x: Float(dx) / scale, y: Float(dy) / scale))
    }
}
#endif
