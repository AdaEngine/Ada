//
//  FileWatcher.swift
//  AdaEngine
//
//  Created by v.prusakov on 5/19/24.
//

// TODO: Add support for events like create, delete, modify, etc.

// Take from https://github.com/swiftlang/swift-tools-support-core/blob/main/Sources/TSCUtility/FSWatch.swift

import Foundation
import Logging

#if canImport(Dispatch)
    import Dispatch
#endif
#if os(Windows)
    import WinSDK
#endif

public typealias FileWatcher = FSWatch

/// FSWatch is a cross-platform filesystem watching utility.
public final class FSWatch: @unchecked Sendable {
    public typealias EventReceivedBlock = @Sendable (_ paths: [AbsolutePath]) -> Void

    /// Delegate for handling events from the underling watcher.
    final class _WatcherDelegate: @unchecked Sendable {
        let block: EventReceivedBlock

        init(block: @escaping EventReceivedBlock) {
            self.block = block
        }

        func pathsDidReceiveEvent(_ paths: [AbsolutePath]) {
            block(paths)
        }
    }

    private var isStarted = false
    private let watcherHandler: _WatcherDelegate

    /// The paths being watched.
    public let paths: [AbsolutePath]

    /// The underlying file watching utility.
    ///
    /// This is FSEventStream on macOS and inotify on linux.
    private var _watcher: _FileWatcher!

    /// The number of seconds the watcher should wait before passing the
    /// collected events to the clients.
    let latency: Double

    /// Create an instance with given paths.
    ///
    /// Paths can be files or directories. Directories are watched recursively.
    public init(paths: [AbsolutePath], latency: Double = 1, block: @escaping EventReceivedBlock) {
        precondition(!paths.isEmpty)
        self.paths = paths
        self.latency = latency
        let watcherDelegate = _WatcherDelegate(block: block)
        self.watcherHandler = watcherDelegate

        #if WASM || os(OpenBSD) || os(FreeBSD)
            self._watcher = NoOpWatcher(paths: paths, latency: latency, delegate: watcherDelegate)
        #elseif os(Windows)
            self._watcher = RDCWatcher(paths: paths, latency: latency, delegate: watcherDelegate)
        #elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
            var ipaths: [AbsolutePath: Inotify.WatchOptions] = [:]

            // FIXME: We need to recurse here.
            for path in paths {
                if localFileSystem.isDirectory(path) {
                    ipaths[path] = .defaultDirectoryWatchOptions
                } else if localFileSystem.isFile(path) {
                    ipaths[path] = .defaultFileWatchOptions
                    // Watch files.
                } else {
                    // FIXME: Report errors
                }
            }

            self._watcher = Inotify(paths: ipaths, latency: latency, delegate: watcherDelegate)
        #elseif os(macOS)
            self._watcher = FSEventStream(paths: paths, latency: latency, delegate: watcherDelegate)
        #else
            fatalError("Unsupported platform")
        #endif
    }

    deinit {
        _watcher.stop()
        isStarted = false
    }

    /// Start watching the filesystem for events.
    ///
    /// This method should be called only once.
    public func start() throws {
        precondition(isStarted == false, "FSWatcher must be started only once")
        // FIXME: Write precondition to ensure its called only once.
        try _watcher.start()
        isStarted = true
    }

    /// Stop watching the filesystem.
    ///
    /// This method should be called after start() and the object should be thrown away.
    public func stop() {
        // FIXME: Write precondition to ensure its called after start() and once only.
        _watcher.stop()
    }
}

/// Protocol to which the different file watcher implementations should conform.
private protocol _FileWatcher {
    func start() throws
    func stop()
}

#if WASM || os(OpenBSD) || os(FreeBSD) || (!os(macOS) && canImport(Darwin))
    extension FSWatch._WatcherDelegate: NoOpWatcherDelegate {}
    extension NoOpWatcher: _FileWatcher {}
#elseif os(Windows)
    extension FSWatch._WatcherDelegate: RDCWatcherDelegate {}
    extension RDCWatcher: _FileWatcher {}
#elseif canImport(Glibc) || canImport(Musl) || canImport(Android)
    extension FSWatch._WatcherDelegate: InotifyDelegate {}
    extension Inotify: _FileWatcher {}
#elseif os(macOS)
    extension FSWatch._WatcherDelegate: FSEventStreamDelegate {}
    extension FSEventStream: _FileWatcher {}
#else
    #error("Implementation required")
#endif

// MARK: - inotify

#if WASM || os(FreeBSD) || os(OpenBSD) || (!os(macOS) && canImport(Darwin))

    public protocol NoOpWatcherDelegate: AnyObject {
        func pathsDidReceiveEvent(_ paths: [AbsolutePath])
    }

    public final class NoOpWatcher {
        public init(paths _: [AbsolutePath], latency _: Double, delegate _: NoOpWatcherDelegate? = nil) {
        }

        public func start() throws {}

        public func stop() {}
    }

#elseif os(Windows)

    public protocol RDCWatcherDelegate: AnyObject, Sendable {
        func pathsDidReceiveEvent(_ paths: [AbsolutePath])
    }

    /// Bindings for `ReadDirectoryChangesW` C APIs.
    public final class RDCWatcher {
        @safe
        class Watch: @unchecked Sendable {
            var hDirectory: HANDLE
            let path: String
            var overlapped: OVERLAPPED
            var terminate: HANDLE
            var buffer: UnsafeMutableBufferPointer<DWORD>  // buffer must be DWORD-aligned
            var thread: TSCBasic.Thread?

            public init(directory handle: HANDLE, _ path: String) {
                unsafe self.hDirectory = handle
                self.path = path
                unsafe self.overlapped = OVERLAPPED()
                unsafe self.overlapped.hEvent = CreateEventW(nil, false, false, nil)
                unsafe self.terminate = CreateEventW(nil, true, false, nil)

                let EntrySize: Int =
                    MemoryLayout<FILE_NOTIFY_INFORMATION>.stride + (Int(MAX_PATH) * MemoryLayout<WCHAR>.stride)
                unsafe self.buffer =
                    UnsafeMutableBufferPointer<DWORD>.allocate(capacity: EntrySize * 4 / MemoryLayout<DWORD>.stride)
            }

            deinit {
                unsafe SetEvent(self.terminate)
                unsafe CloseHandle(self.terminate)
                unsafe CloseHandle(self.overlapped.hEvent)
                unsafe CloseHandle(hDirectory)
                unsafe self.buffer.deallocate()
            }
        }

        /// The paths being watched.
        private let paths: [AbsolutePath]

        /// The settle period (in seconds).
        private let settle: Double

        /// The watcher delegate.
        private weak var delegate: RDCWatcherDelegate?

        private let watches: [Watch]
        private let queue: DispatchQueue =
            DispatchQueue(label: "org.adaengine.\(RDCWatcher.self).callback")

        public init(paths: [AbsolutePath], latency: Double, delegate: RDCWatcherDelegate? = nil) {
            self.paths = paths
            self.settle = latency
            self.delegate = delegate

            self.watches = paths.map {
                unsafe $0.pathString.withCString(encodedAs: UTF16.self) {
                    let dwDesiredAccess: DWORD = DWORD(FILE_LIST_DIRECTORY)
                    let dwShareMode: DWORD = DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE)
                    let dwCreationDisposition: DWORD = DWORD(OPEN_EXISTING)
                    let dwFlags: DWORD = DWORD(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OVERLAPPED)

                    let handle: HANDLE =
                        unsafe CreateFileW(
                            $0,
                            dwDesiredAccess,
                            dwShareMode,
                            nil,
                            dwCreationDisposition,
                            dwFlags,
                            nil
                        )
                    unsafe assert(!(handle == INVALID_HANDLE_VALUE))

                    let dwSize: DWORD = unsafe GetFinalPathNameByHandleW(handle, nil, 0, 0)
                    // GetFinalPathNameByHandleW returns the size including null terminator
                    // Allocate buffer with size + 1 to ensure we have space for null terminator
                    let bufferSize = Int(dwSize) + 1
                    var pathBuffer = [WCHAR](repeating: 0, count: bufferSize)
                    let actualSize: DWORD = unsafe GetFinalPathNameByHandleW(handle, &pathBuffer, DWORD(bufferSize), 0)
                    // actualSize should be <= bufferSize and includes null terminator
                    assert(actualSize <= DWORD(bufferSize), "GetFinalPathNameByHandleW returned size \(actualSize) exceeding buffer size \(bufferSize)")
                    // Ensure null terminator is present
                    pathBuffer[Int(actualSize)] = 0
                    let path: String = unsafe String(decodingCString: pathBuffer, as: UTF16.self)

                    return unsafe Watch(directory: handle, path)
                }
            }
        }

        public func start() throws {
            // TODO(compnerd) can we compress the threads to a single worker thread
            self.watches.forEach { watch in
                watch.thread = TSCBasic.Thread { [delegate = self.delegate, queue = self.queue, weak watch] in
                    guard let watch else {
                        return
                    }

                    while true {
                        let dwNotifyFilter: DWORD =
                            DWORD(FILE_NOTIFY_CHANGE_FILE_NAME)
                            | DWORD(FILE_NOTIFY_CHANGE_DIR_NAME)
                            | DWORD(FILE_NOTIFY_CHANGE_SIZE)
                            | DWORD(FILE_NOTIFY_CHANGE_LAST_WRITE)
                            | DWORD(FILE_NOTIFY_CHANGE_CREATION)
                        var dwBytesReturned: DWORD = 0
                        if unsafe !ReadDirectoryChangesW(
                            watch.hDirectory,
                            &watch.buffer,
                            DWORD(watch.buffer.count * MemoryLayout<DWORD>.stride),
                            true,
                            dwNotifyFilter,
                            &dwBytesReturned,
                            &watch.overlapped,
                            nil
                        ) {
                            return
                        }

                        var handles: (HANDLE?, HANDLE?) = unsafe (watch.terminate, watch.overlapped.hEvent)
                        switch unsafe WaitForMultipleObjects(2, &handles.0, false, INFINITE) {
                        case WAIT_OBJECT_0 + 1:
                            break
                        case DWORD(WAIT_TIMEOUT):  // Spurious Wakeup?
                            continue
                        case WAIT_FAILED, WAIT_OBJECT_0:  // Terminate Request
                            unsafe CloseHandle(watch.hDirectory)
                            unsafe watch.hDirectory = INVALID_HANDLE_VALUE
                            return
                        default:
                            unsafe CloseHandle(watch.hDirectory)
                            unsafe watch.hDirectory = INVALID_HANDLE_VALUE
                            return
                        }

                        if unsafe !GetOverlappedResult(watch.hDirectory, &watch.overlapped, &dwBytesReturned, false) {
                            queue.async {
                                delegate?.pathsDidReceiveEvent([AbsolutePath(watch.path)])
                            }
                            return
                        }

                        // There was a buffer underrun on the kernel side.  We may
                        // have lost events, please re-synchronize.
                        if dwBytesReturned == 0 {
                            return
                        }

                        var paths: [AbsolutePath] = []
                        unsafe watch.buffer.withMemoryRebound(to: FILE_NOTIFY_INFORMATION.self) {
                            let pNotify: UnsafeMutablePointer<FILE_NOTIFY_INFORMATION>? =
                                $0.baseAddress
                            while var pNotify = unsafe pNotify {
                                // FIXME(compnerd) do we care what type of event was received?
                                let file = unsafe String(utf16CodeUnits: &pNotify.pointee.FileName, count: Int(pNotify.pointee.FileNameLength) / MemoryLayout<WCHAR>.stride)
                                if let path = try? AbsolutePath(validating: file) {
                                    paths.append(path)
                                }

                                unsafe pNotify = (UnsafeMutableRawPointer(pNotify) + Int(pNotify.pointee.NextEntryOffset))
                                    .assumingMemoryBound(to: FILE_NOTIFY_INFORMATION.self)
                            }
                        }

                        queue.async { [paths] in
                            delegate?.pathsDidReceiveEvent(paths)
                        }
                    }
                }
                watch.thread?.start()
            }
        }

        public func stop() {
            self.watches.forEach {
                unsafe SetEvent($0.terminate)
                $0.thread?.join()
            }
        }
    }

#elseif canImport(Glibc) || canImport(Musl) || canImport(Android)

    /// The delegate for receiving inotify events.
    public protocol InotifyDelegate: AnyObject {
        func pathsDidReceiveEvent(_ paths: [AbsolutePath])
    }

    /// Bindings for inotify C APIs.
    public final class Inotify {
        /// The errors encountered during inotify operations.
        public enum Error: Swift.Error {
            case invalidFD
            case failedToWatch(AbsolutePath)
        }

        /// The available options for a particular path.
        public struct WatchOptions: OptionSet {
            public let rawValue: Int32

            public init(rawValue: Int32) {
                self.rawValue = rawValue
            }

            // File/directory created in watched directory (e.g., open(2)
            // O_CREAT, mkdir(2), link(2), symlink(2), bind(2) on a UNIX
            // domain socket).
            public static let create = Self(rawValue: IN_CREATE)

            // File/directory deleted from watched directory.
            public static let delete = Self(rawValue: IN_DELETE)

            // Watched file/directory was itself deleted.  (This event
            // also occurs if an object is moved to another filesystem,
            // since mv(1) in effect copies the file to the other
            // filesystem and then deletes it from the original filesys‐
            // tem.)  In addition, an IN_IGNORED event will subsequently
            // be generated for the watch descriptor.
            public static let deleteSelf = Self(rawValue: IN_DELETE_SELF)

            public static let move = Self(rawValue: IN_MOVE)

            /// Watched file/directory was itself moved.
            public static let moveSelf = Self(rawValue: IN_MOVE_SELF)

            /// File was modified (e.g., write(2), truncate(2)).
            public static let modify = Self(rawValue: IN_MODIFY)

            // File or directory was opened.
            public static let open = Self(rawValue: IN_OPEN)

            // Metadata changed—for example, permissions (e.g.,
            // chmod(2)), timestamps (e.g., utimensat(2)), extended
            // attributes (setxattr(2)), link count (since Linux 2.6.25;
            // e.g., for the target of link(2) and for unlink(2)), and
            // user/group ID (e.g., chown(2)).
            public static let attrib = Self(rawValue: IN_ATTRIB)

            // File opened for writing was closed.
            public static let closeWrite = Self(rawValue: IN_CLOSE_WRITE)

            // File or directory not opened for writing was closed.
            public static let closeNoWrite = Self(rawValue: IN_CLOSE_NOWRITE)

            // File was accessed (e.g., read(2), execve(2)).
            public static let access = Self(rawValue: IN_ACCESS)

            /// The list of default options that can be used for watching files.
            public static let defaultFileWatchOptions: WatchOptions = [.deleteSelf, .moveSelf, .modify]

            /// The list of default options that can be used for watching directories.
            public static let defaultDirectoryWatchOptions: WatchOptions = [.create, .delete, .deleteSelf, .move, .moveSelf]

            /// List of all available events.
            public static let all: [Self] = [
                .create,
                .delete,
                .deleteSelf,
                .move,
                .moveSelf,
                .modify,
                .open,
                .attrib,
                .closeWrite,
                .closeNoWrite,
                .access,
            ]
        }

        // Sizeof inotify_event + max len of filepath + 1 (for null char).
        private static let eventSize = MemoryLayout<inotify_event>.size + Int(NAME_MAX) + 1

        /// The paths being watched.
        public let paths: [AbsolutePath: WatchOptions]

        /// The delegate.
        private weak var delegate: InotifyDelegate?

        /// The settle period (in seconds).
        public let settle: Double

        /// Internal properties.
        private var fd: Int32?

        /// The list of watched directories/files.
        private var wds: [Int32: AbsolutePath] = [:]

        /// The queue on which we read the events.
        private let readQueue = DispatchQueue(label: "org.adaengine.\(Inotify.self).read")

        /// Callback queue for the delegate.
        private let callbacksQueue = DispatchQueue(label: "org.adaengine.\(Inotify.self).callback")

        /// Condition for handling event reporting.
        private var reportCondition = Condition()

        // Should be read or written to using the report condition only.
        private var collectedEvents: [AbsolutePath] = []

        // Should be read or written to using the report condition only.
        private var lastEventTime: Date?

        // Should be read or written to using the report condition only.
        private var cancelled = false

        /// Pipe for waking up the read loop.
        private var cancellationPipe: [Int32] = [0, 0]

        /// Create a inotify instance.
        ///
        /// The paths are not watched recursively.
        public init(paths: [AbsolutePath: WatchOptions], latency: Double, delegate: InotifyDelegate? = nil) {
            self.paths = paths
            self.delegate = delegate
            self.settle = latency
        }

        /// Start the watch operation.
        public func start() throws {
            // All paths need to exist.
            for (path, _) in paths {
                guard localFileSystem.exists(path) else {
                    throw Error.failedToWatch(path)
                }
            }

            // Create the file descriptor.
            let fd = inotify_init1(Int32(IN_NONBLOCK))

            guard fd != -1 else {
                throw Error.invalidFD
            }
            self.fd = fd

            /// Add watch for each path.
            for (path, options) in paths {
                let wd = inotify_add_watch(fd, path.description, UInt32(options.rawValue))
                guard wd != -1 else {
                    throw Error.failedToWatch(path)
                }

                self.wds[wd] = path
            }

            // Start the report thread.
            startReportThread()

            readQueue.async {
                self.startRead()
            }
        }

        /// End the watch operation.
        public func stop() {
            // FIXME: Write precondition to ensure this is called only once.
            guard let fd else {
                assertionFailure("end called without a fd")
                return
            }

            // Shutdown the report thread.
            reportCondition.whileLocked {
                cancelled = true
                reportCondition.signal()
            }

            // Wakeup the read loop by writing on the cancellation pipe.
            let writtenData = write(cancellationPipe[1], "", 1)
            assert(writtenData == 1)

            // FIXME: We need to remove the watches.
            close(fd)
        }

        private func startRead() {
            guard let fd else {
                fatalError("unexpected call to startRead without fd")
            }

            // Create a pipe that we can use to get notified when we're cancelled.
            let pipeRv = pipe(&cancellationPipe)
            // FIXME: We don't see pipe2 for some reason.
            let f = fcntl(cancellationPipe[0], F_SETFL, O_NONBLOCK)
            assert(f != -1)
            assert(pipeRv == 0)

            while true {
                // The read fd set. Contains the inotify and cancellation fd.
                var rfds = fd_set()
                FD_ZERO(&rfds)

                FD_SET(fd, &rfds)
                FD_SET(cancellationPipe[0], &rfds)

                let nfds = [fd, cancellationPipe[0]].reduce(0, max) + 1
                // num fds, read fds, write fds, except fds, timeout
                let selectRet = select(nfds, &rfds, nil, nil, nil)
                // FIXME: Check for int signal.
                assert(selectRet != -1)

                // Return if we're cancelled.
                if FD_ISSET(cancellationPipe[0], &rfds) {
                    return
                }
                assert(FD_ISSET(fd, &rfds))

                let buf = UnsafeMutablePointer<CChar>.allocate(capacity: Self.eventSize)
                // FIXME: We need to free the buffer.

                let readLength = read(fd, buf, Self.eventSize)
                // FIXME: Check for int signal.

                // Consume events.
                var idx = 0
                while idx < readLength {
                    let event = withUnsafePointer(to: &buf[idx]) {
                        $0.withMemoryRebound(to: inotify_event.self, capacity: 1) {
                            $0.pointee
                        }
                    }

                    // Get the associated with the event.
                    guard var path = wds[event.wd] else {
                        continue
                    }

                    // FIXME: We need extract information from the event mask and
                    // create a data structure.
                    // FIXME: Do we need to detect and remove watch for directories
                    // that are deleted?

                    // Get the relative base name from the event if present.
                    if event.len > 0 {
                        // Get the basename of the file that had the event.
                        let basename = String(cString: buf + idx + MemoryLayout<inotify_event>.size)

                        // Construct the full path.
                        // FIXME: We should report this path separately.
                        path = path.appending(component: basename)
                    }

                    // Signal the reporter.
                    reportCondition.whileLocked {
                        lastEventTime = Date()
                        collectedEvents.append(path)
                        reportCondition.signal()
                    }

                    idx += MemoryLayout<inotify_event>.size + Int(event.len)
                }
            }
        }

        /// Spawns a thread that collects events and reports them after the settle period.
        private func startReportThread() {
            let thread = TSCBasic.Thread {
                var endLoop = false
                while !endLoop {
                    // Block until we timeout or get signalled.
                    self.reportCondition.whileLocked {
                        var performReport = false

                        // Block until timeout expires or wait forever until we get some event.
                        if let lastEventTime = self.lastEventTime {
                            let timeout = lastEventTime + Double(self.settle)
                            let timeLimitReached = !self.reportCondition.wait(until: timeout)

                            if timeLimitReached {
                                self.lastEventTime = nil
                                performReport = true
                            }
                        } else {
                            self.reportCondition.wait()
                        }

                        // If we're cancelled, just return.
                        if self.cancelled {
                            endLoop = true
                            return
                        }

                        // Report the events if we're asked to.
                        if performReport && !self.collectedEvents.isEmpty {
                            let events = self.collectedEvents
                            self.collectedEvents = []
                            self.callbacksQueue.async {
                                self.report(events)
                            }
                        }
                    }
                }
            }

            thread.start()
        }

        private func report(_ paths: [AbsolutePath]) {
            delegate?.pathsDidReceiveEvent(paths)
        }
    }

    // FIXME: <rdar://problem/45794219> Swift should provide shims for FD_ macros

    private func FD_ZERO(_ set: inout fd_set) {
        #if os(Android) || canImport(Musl)
            #if arch(arm)
                set.fds_bits = (
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0
                )
            #else
                set.fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            #endif
        #else
            #if arch(arm)
                set.__fds_bits = (
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0,
                    0
                )
            #else
                set.__fds_bits = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
            #endif
        #endif
    }

    private func FD_SET(_ fd: Int32, _ set: inout fd_set) {
        let intOffset = Int(fd / 16)
        let bitOffset = Int(fd % 16)
        #if os(Android) || canImport(Musl)
            var fd_bits = set.fds_bits
            let mask: UInt = 1 << bitOffset
        #else
            var fd_bits = set.__fds_bits
            let mask = 1 << bitOffset
        #endif
        switch intOffset {
        case 0: fd_bits.0 = fd_bits.0 | mask
        case 1: fd_bits.1 = fd_bits.1 | mask
        case 2: fd_bits.2 = fd_bits.2 | mask
        case 3: fd_bits.3 = fd_bits.3 | mask
        case 4: fd_bits.4 = fd_bits.4 | mask
        case 5: fd_bits.5 = fd_bits.5 | mask
        case 6: fd_bits.6 = fd_bits.6 | mask
        case 7: fd_bits.7 = fd_bits.7 | mask
        case 8: fd_bits.8 = fd_bits.8 | mask
        case 9: fd_bits.9 = fd_bits.9 | mask
        case 10: fd_bits.10 = fd_bits.10 | mask
        case 11: fd_bits.11 = fd_bits.11 | mask
        case 12: fd_bits.12 = fd_bits.12 | mask
        case 13: fd_bits.13 = fd_bits.13 | mask
        case 14: fd_bits.14 = fd_bits.14 | mask
        case 15: fd_bits.15 = fd_bits.15 | mask
        #if arch(arm)
            case 16: fd_bits.16 = fd_bits.16 | mask
            case 17: fd_bits.17 = fd_bits.17 | mask
            case 18: fd_bits.18 = fd_bits.18 | mask
            case 19: fd_bits.19 = fd_bits.19 | mask
            case 20: fd_bits.20 = fd_bits.20 | mask
            case 21: fd_bits.21 = fd_bits.21 | mask
            case 22: fd_bits.22 = fd_bits.22 | mask
            case 23: fd_bits.23 = fd_bits.23 | mask
            case 24: fd_bits.24 = fd_bits.24 | mask
            case 25: fd_bits.25 = fd_bits.25 | mask
            case 26: fd_bits.26 = fd_bits.26 | mask
            case 27: fd_bits.27 = fd_bits.27 | mask
            case 28: fd_bits.28 = fd_bits.28 | mask
            case 29: fd_bits.29 = fd_bits.29 | mask
            case 30: fd_bits.30 = fd_bits.30 | mask
            case 31: fd_bits.31 = fd_bits.31 | mask
        #endif
        default: break
        }
        #if os(Android) || canImport(Musl)
            set.fds_bits = fd_bits
        #else
            set.__fds_bits = fd_bits
        #endif
    }

    private func FD_ISSET(_ fd: Int32, _ set: inout fd_set) -> Bool {
        let intOffset = Int(fd / 32)
        let bitOffset = Int(fd % 32)
        #if os(Android) || canImport(Musl)
            let fd_bits = set.fds_bits
            let mask: UInt = 1 << bitOffset
        #else
            let fd_bits = set.__fds_bits
            let mask = 1 << bitOffset
        #endif
        switch intOffset {
        case 0: return fd_bits.0 & mask != 0
        case 1: return fd_bits.1 & mask != 0
        case 2: return fd_bits.2 & mask != 0
        case 3: return fd_bits.3 & mask != 0
        case 4: return fd_bits.4 & mask != 0
        case 5: return fd_bits.5 & mask != 0
        case 6: return fd_bits.6 & mask != 0
        case 7: return fd_bits.7 & mask != 0
        case 8: return fd_bits.8 & mask != 0
        case 9: return fd_bits.9 & mask != 0
        case 10: return fd_bits.10 & mask != 0
        case 11: return fd_bits.11 & mask != 0
        case 12: return fd_bits.12 & mask != 0
        case 13: return fd_bits.13 & mask != 0
        case 14: return fd_bits.14 & mask != 0
        case 15: return fd_bits.15 & mask != 0
        #if arch(arm)
            case 16: return fd_bits.16 & mask != 0
            case 17: return fd_bits.17 & mask != 0
            case 18: return fd_bits.18 & mask != 0
            case 19: return fd_bits.19 & mask != 0
            case 20: return fd_bits.20 & mask != 0
            case 21: return fd_bits.21 & mask != 0
            case 22: return fd_bits.22 & mask != 0
            case 23: return fd_bits.23 & mask != 0
            case 24: return fd_bits.24 & mask != 0
            case 25: return fd_bits.25 & mask != 0
            case 26: return fd_bits.26 & mask != 0
            case 27: return fd_bits.27 & mask != 0
            case 28: return fd_bits.28 & mask != 0
            case 29: return fd_bits.29 & mask != 0
            case 30: return fd_bits.30 & mask != 0
            case 31: return fd_bits.31 & mask != 0
        #endif
        default: return false
        }
    }

#endif

// MARK: - FSEventStream

#if os(macOS)

    private func callback(
        streamRef _: ConstFSEventStreamRef,
        clientCallBackInfo: UnsafeMutableRawPointer?,
        numEvents _: Int,
        eventPaths: UnsafeMutableRawPointer,
        eventFlags _: UnsafePointer<FSEventStreamEventFlags>,
        eventIds _: UnsafePointer<FSEventStreamEventId>
    ) {
        let eventStream = unsafe unsafeBitCast(clientCallBackInfo, to: FSEventStream.self)

        // We expect the paths to be reported as a CFArray because we requested CFTypes.
        let eventPaths = unsafe unsafeBitCast(eventPaths, to: CFArray.self) as? [String] ?? []

        // Compute the set of paths that were changed.
        do {
            let paths = try eventPaths.compactMap { try AbsolutePath(validating: $0) }

            eventStream.callbacksQueue.async {
                eventStream.delegate?.pathsDidReceiveEvent(paths)
            }
        } catch {
            Logger(label: "org.adaengine.utils.filewatcher").error("\(error.localizedDescription)")
        }
    }

    public protocol FSEventStreamDelegate: AnyObject {
        func pathsDidReceiveEvent(_ paths: [AbsolutePath])
    }

    /// Wrapper for Darwin's FSEventStream API.
    @safe
    public final class FSEventStream: @unchecked Sendable {
        /// The errors encountered during fs event watching.
        public enum Error: Swift.Error {
            case unknownError
        }

        /// Reference to the underlying event stream.
        ///
        private var stream: FSEventStreamRef?

        /// Reference to the handler that should be called.
        weak var delegate: FSEventStreamDelegate?

        /// Callback queue for the delegate.
        let callbacksQueue = DispatchQueue(label: "org.adaengine.\(FSEventStream.self).callback")
        private let streamQueue = DispatchQueue(label: "org.adaengine.\(FSEventStream.self).stream")

        public init(
            paths: [AbsolutePath],
            latency: Double,
            delegate: FSEventStreamDelegate,
            flags: FSEventStreamCreateFlags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents)
        ) {
            self.delegate = delegate

            // Create the context that needs to be passed to the callback.
            var callbackContext = unsafe FSEventStreamContext()
            unsafe callbackContext.info = unsafeBitCast(self, to: UnsafeMutableRawPointer.self)

            // Convert AbsolutePath array to String array for FSEventStreamCreate
            let pathStrings = paths.map(\.pathString)
            let pathsArray = pathStrings as CFArray

            // Create the stream.
            unsafe self.stream = FSEventStreamCreate(
                nil,
                callback,
                &callbackContext,

                pathsArray,

                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                flags
            )
        }

        // Start delivery on a dispatch queue.
        public func start() throws {
            guard let stream = unsafe self.stream else {
                throw Error.unknownError
            }
            unsafe FSEventStreamSetDispatchQueue(stream, streamQueue)
            guard unsafe FSEventStreamStart(stream) else {
                unsafe FSEventStreamSetDispatchQueue(stream, nil)
                throw Error.unknownError
            }
        }

        /// Stop watching the events.
        public func stop() {
            guard let stream = unsafe self.stream else {
                return
            }
            unsafe FSEventStreamStop(stream)
            unsafe FSEventStreamSetDispatchQueue(stream, nil)
            unsafe FSEventStreamInvalidate(stream)
            unsafe FSEventStreamRelease(stream)
            unsafe self.stream = nil
        }
    }
#endif

#if !os(WASI)
    enum TSCBasic {
        /// This class bridges the gap between Darwin and Linux Foundation Threading API.
        /// It provides closure based execution and a join method to block the calling thread
        /// until the thread is finished executing.
        public final class Thread: @unchecked Sendable {
            /// The thread implementation which is Foundation.Thread on Linux and
            /// a Thread subclass which provides closure support on Darwin.
            private var thread: ThreadImpl!

            /// Condition variable to support blocking other threads using join when this thread has not finished executing.
            private var finishedCondition: Condition

            /// A boolean variable to track if this thread has finished executing its task.
            private var isFinished: Bool

            /// Creates an instance of thread class with closure to be executed when start() is called.
            public init(task: @escaping @Sendable () -> Void) {
                isFinished = false
                finishedCondition = Condition()

                // Wrap the task with condition notifying any other threads blocked due to this thread.
                // Capture self weakly to avoid reference cycle. In case Thread is deinited before the task
                // runs, skip the use of finishedCondition.
                let theTask: @Sendable () -> Void = { [weak self] in
                    if let strongSelf = self {
                        precondition(!strongSelf.isFinished)
                        strongSelf.finishedCondition.whileLocked {
                            task()
                            strongSelf.isFinished = true
                            strongSelf.finishedCondition.broadcast()
                        }
                    } else {
                        // If the containing thread has been destroyed, we can ignore the finished condition and just run the
                        // task.
                        task()
                    }
                }

                self.thread = ThreadImpl(block: theTask)
            }

            /// Starts the thread execution.
            public func start() {
                thread.start()
            }

            /// Blocks the calling thread until this thread is finished execution.
            public func join() {
                finishedCondition.whileLocked {
                    while !isFinished {
                        finishedCondition.wait()
                    }
                }
            }

            /// Causes the calling thread to yield execution to another thread.
            public static func yield() {
                #if os(Windows)
                    SwitchToThread()
                #else
                    sched_yield()
                #endif
            }
        }

        #if canImport(Darwin)
            /// A helper subclass of Foundation's Thread with closure support.
            private final class ThreadImpl: Foundation.Thread {
                /// The task to be executed.
                private let task: @Sendable () -> Void

                override func main() {
                    task()
                }

                init(block task: @escaping @Sendable () -> Void) {
                    self.task = task
                }
            }
        #else
            // Thread on Linux supports closure so just use it directly.
            typealias ThreadImpl = Foundation.Thread
        #endif

        public struct Condition: Sendable {
            private let _condition = NSCondition()

            /// Create a new condition.
            public init() {}

            /// Wait for the condition to become available.
            public func wait() {
                _condition.wait()
            }

            /// Blocks the current thread until the condition is signaled or the specified time limit is reached.
            ///
            /// - Returns: true if the condition was signaled; otherwise, false if the time limit was reached.
            public func wait(until limit: Date) -> Bool {
                return _condition.wait(until: limit)
            }

            /// Signal the availability of the condition (awake one thread waiting on
            /// the condition).
            public func signal() {
                _condition.signal()
            }

            /// Broadcast the availability of the condition (awake all threads waiting
            /// on the condition).
            public func broadcast() {
                _condition.broadcast()
            }

            /// A helper method to execute the given body while condition is locked.
            /// - Note: Will ensure condition unlocks even if `body` throws.
            public func whileLocked<T>(_ body: () throws -> T) rethrows -> T {
                _condition.lock()
                defer { _condition.unlock() }
                return try body()
            }
        }
    }
#endif
