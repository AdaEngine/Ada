#if os(macOS)
import Darwin
import Foundation

/// An advisory lock releases automatically on process exit, including SIGKILL.
struct EditorCLIBuildLock {
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
}
#endif
