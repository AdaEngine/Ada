#if os(Windows)
import Foundation
import ucrt
import WinSDK

/// Console handlers run on an OS thread. Only the callback is shared; cancellation
/// is forwarded to Swift tasks and the process runner's Windows job objects.
final class EditorCLIWindowsInterrupt: @unchecked Sendable {
    /// The GUI image attaches to the launcher's console before running CLI commands.
    @MainActor
    static func attachToParentConsole() {
        guard AttachConsole(DWORD.max) else { // ATTACH_PARENT_PROCESS
            return
        }
        unsafe reconnectConsoleStream(DWORD(STD_INPUT_HANDLE), stdin, path: "CONIN$", mode: "r")
        unsafe reconnectConsoleStream(DWORD(STD_OUTPUT_HANDLE), stdout, path: "CONOUT$", mode: "w")
        unsafe reconnectConsoleStream(DWORD(STD_ERROR_HANDLE), stderr, path: "CONOUT$", mode: "w")
    }

    private static func reconnectConsoleStream(_ handleID: DWORD, _ stream: UnsafeMutablePointer<FILE>, path: String, mode: String) {
        var consoleMode: DWORD = 0
        // AttachConsole updates Win32 handles. Foundation FileHandle reads the CRT
        // descriptors, which still point at the old handles. Preserve redirected files/pipes.
        guard unsafe GetConsoleMode(GetStdHandle(handleID), &consoleMode) else {
            return
        }
        var reopened: UnsafeMutablePointer<FILE>?
        _ = unsafe freopen_s(&reopened, path, mode, stream)
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var callback: (@Sendable () -> Void)?
    }
    private static let state = State()
    private static let handler: PHANDLER_ROUTINE = { event in
        guard event == DWORD(CTRL_C_EVENT) || event == DWORD(CTRL_BREAK_EVENT) else {
            return false
        }
        let callback = state.lock.withLock { state.callback }
        guard let callback else {
            return false
        }
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
