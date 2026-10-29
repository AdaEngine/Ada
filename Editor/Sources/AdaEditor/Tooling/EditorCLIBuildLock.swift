#if os(macOS) || os(Windows)
#if os(macOS)
import Darwin
#else
import WinSDK
#endif
import Foundation

/// An advisory lock releases automatically on process exit, including SIGKILL.
struct EditorCLIBuildLock {
    #if os(Windows)
    private let handle: HANDLE

    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let path = Array(url.path.replacingOccurrences(of: "/", with: "\\").utf16) + [0]
        let handle = path.withUnsafeBufferPointer {
            CreateFileW($0.baseAddress, DWORD(GENERIC_READ) | DWORD(GENERIC_WRITE), 0, nil, DWORD(OPEN_ALWAYS), DWORD(FILE_ATTRIBUTE_NORMAL), nil)
        }
        guard let handle, handle != INVALID_HANDLE_VALUE else {
            throw EditorCLIError.environment("Cannot acquire build lock; another CLI build may be using this project: \(url.path)")
        }
        self.handle = handle
    }

    func release() { CloseHandle(handle) }
    #else
    private let descriptor: Int32

    init(at url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let descriptor = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw EditorCLIError.environment("Cannot open build lock: \(url.path)") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            close(descriptor)
            throw EditorCLIError.environment("Another CLI build is using this project: \(url.path)")
        }
        self.descriptor = descriptor
    }

    func release() {
        flock(descriptor, LOCK_UN)
        close(descriptor)
    }
    #endif
}
#endif
