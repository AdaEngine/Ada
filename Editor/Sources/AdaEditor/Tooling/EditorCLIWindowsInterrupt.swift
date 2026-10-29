#if os(Windows)
import Foundation
import WinSDK

/// Console handlers run on an OS thread. Only the callback is shared; cancellation
/// is forwarded to Swift tasks and the process runner's Windows job objects.
final class EditorCLIWindowsInterrupt: @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var callback: (@Sendable () -> Void)?
    }
    private static let state = State()
    private static let handler: PHANDLER_ROUTINE = { event in
        guard event == DWORD(CTRL_C_EVENT) || event == DWORD(CTRL_BREAK_EVENT) else { return false }
        let callback = state.lock.withLock { state.callback }
        guard let callback else { return false }
        callback()
        return true
    }

    init(_ callback: @escaping @Sendable () -> Void) {
        Self.state.lock.withLock { Self.state.callback = callback }
        SetConsoleCtrlHandler(Self.handler, true)
    }

    func close() {
        SetConsoleCtrlHandler(Self.handler, false)
        Self.state.lock.withLock { Self.state.callback = nil }
    }
}
#endif
