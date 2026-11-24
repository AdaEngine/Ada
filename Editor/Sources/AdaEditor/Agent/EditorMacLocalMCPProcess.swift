#if os(macOS)
import Darwin
import Dispatch
import Foundation

/// Owns the process group so inherited stdio is released when the launcher exits or Studio disconnects.
final class EditorLocalMCPProcess: Sendable {
    private let lifetime: Lifetime
    let input: FileHandle
    let output: FileHandle
    let error: FileHandle

    init(executable: URL, arguments: [String], directory: URL, environment: [String: String]) throws {
        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        input = stdin.fileHandleForWriting
        output = stdout.fileHandleForReading
        error = stderr.fileHandleForReading
        try Self.check(fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1) == -1 ? errno : 0)
        for handle in [input, output, error] {
            let flags = fcntl(handle.fileDescriptor, F_GETFL)
            try Self.check(flags == -1 ? errno : 0)
            try Self.check(fcntl(handle.fileDescriptor, F_SETFL, flags | O_NONBLOCK) == -1 ? errno : 0)
        }
        var actions: posix_spawn_file_actions_t?
        try Self.check(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stdin.fileHandleForReading.fileDescriptor, STDIN_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stdout.fileHandleForWriting.fileDescriptor, STDOUT_FILENO))
        try Self.check(posix_spawn_file_actions_adddup2(&actions, stderr.fileHandleForWriting.fileDescriptor, STDERR_FILENO))
        try Self.check(directory.path.withCString { posix_spawn_file_actions_addchdir_np(&actions, $0) })

        var attributes: posix_spawnattr_t?
        try Self.check(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try Self.check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try Self.check(posix_spawnattr_setpgroup(&attributes, 0))
        var pid: pid_t = 0
        try Self.withArguments([executable.path] + arguments) { argv in
            try Self.withArguments(environment.map { "\($0.key)=\($0.value)" }) { envp in
                try Self.check(executable.path.withCString { posix_spawn(&pid, $0, &actions, &attributes, argv, envp) })
            }
        }
        try? stdin.fileHandleForReading.close()
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        let state = Lifetime(pid)
        lifetime = state
        DispatchQueue.global().async { state.reapOnExit() }
    }

    deinit { lifetime.terminate() }
    func terminate() { lifetime.terminate() }
    static func removeEmptyDirectory(_ directory: URL) { _ = directory.path.withCString { Darwin.rmdir($0) } }

    private static func check(_ code: Int32) throws {
        if code != 0 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
    }

    private static func withArguments(_ values: [String], _ body: (UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>) throws -> Void) throws {
        var pointers = values.map { value in value.withCString { strdup($0) } }
        defer { for pointer in pointers { free(pointer) } }
        guard !pointers.contains(where: { $0 == nil }) else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOMEM)) }
        pointers.append(nil)
        try pointers.withUnsafeMutableBufferPointer { buffer in
            if let arguments = buffer.baseAddress { try body(arguments) }
        }
    }

    /// The unreaped leader reserves the PID until its group has been signaled. Mutations and signals share this lock.
    private final class Lifetime: @unchecked Sendable {
        private let lock = NSLock()
        private let pid: pid_t
        private var reaped = false

        init(_ pid: pid_t) { self.pid = pid }

        func terminate() {
            lock.withLock { if !reaped { _ = Darwin.kill(-pid, SIGKILL) } }
        }

        func reapOnExit() {
            var info = siginfo_t()
            var result: Int32
            repeat { result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOWAIT) } while result < 0 && errno == EINTR
            lock.withLock {
                if result == 0 {
                    _ = Darwin.kill(-pid, SIGKILL)
                    while waitpid(pid, nil, 0) < 0 && errno == EINTR {}
                }
                reaped = true
            }
        }
    }
}

actor EditorLocalMCPWriter {
    private let handle: FileHandle
    private let queue = DispatchQueue(label: "org.adaengine.mcp.write")

    init(_ handle: FileHandle) { self.handle = handle }

    func write(_ bytes: Data) async throws {
        let handle = handle
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            queue.async {
                do { try Self.writeFrame(bytes, to: handle); continuation.resume() } catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Keep the whole newline-delimited message on one queue even when the pipe temporarily fills.
    private static func writeFrame(_ bytes: Data, to handle: FileHandle) throws {
        let deadline = ContinuousClock.now + .seconds(10)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(handle.fileDescriptor, buffer.baseAddress?.advanced(by: offset), buffer.count - offset)
            }
            if count > 0 {
                offset += count
                continue
            }
            let code = errno
            guard count == -1, code == EINTR || code == EAGAIN else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            guard ContinuousClock.now < deadline else { throw EditorLocalMCPConnection.Failure.timeout }
            var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&descriptor, 1, 100)
            if ready < 0, errno != EINTR { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
    }
}

enum EditorLocalMCPPipe {
    static func chunks(_ handle: FileHandle) -> AsyncThrowingStream<Data, any Error> {
        let queue = DispatchQueue(label: "org.adaengine.mcp.read")
        return AsyncThrowingStream(unfolding: {
            while true {
                try Task.checkCancellation()
                let data: Data? = try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        do { continuation.resume(returning: try read(handle)) } catch { continuation.resume(throwing: error) }
                    }
                }
                if data?.isEmpty != true { return data }
            }
        })
    }

    /// Empty data is a poll wake-up. EOF is nil. Polling is bounded so cancellation cannot leave a blocked queue.
    private static func read(_ handle: FileHandle) throws -> Data? {
        var descriptor = pollfd(fd: handle.fileDescriptor, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, 200)
        if ready == 0 || (ready < 0 && errno == EINTR) { return Data() }
        guard ready > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var buffer = Data(count: 64 * 1_024)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(handle.fileDescriptor, $0.baseAddress, $0.count) }
        if count > 0 { buffer.count = count; return buffer }
        if count == 0 { return nil }
        if errno == EAGAIN || errno == EINTR { return Data() }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
    }
}
#endif
