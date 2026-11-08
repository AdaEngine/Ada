import Foundation
#if os(Linux)
    import Glibc
#endif
import Gravity
#if os(Windows)
    import WinSDK
#endif

/// An engine-owned temporary save that accepts bounded chunks off the VM thread.
@GSExportable("AdaSaveWriter")
// VM-owned configuration is published once; cancellation is locked and file
// operations are serialized by AdaScriptSaveStreamState.
final class AdaScriptSaveWriter: @unchecked Sendable, AdaScriptSuspensionSafeBridge {
    @GSExportableIgnore
    private var state: AdaScriptSaveStreamState?

    @GSExportableIgnore
    private var path = ""

    @GSExportableIgnore
    private var configurationError: String?

    @GSExportableIgnore
    private var onWake: (@Sendable () -> Void)?

    @GSExportableIgnore
    private let stateLock = NSLock()

    @GSExportableIgnore
    private var didCancel = false

    @GSExportableIgnore
    static func make(
        path: String,
        url: URL?,
        errorCode: String?,
        onWake: (@Sendable () -> Void)?
    ) -> AdaScriptSaveWriter {
        let writer = AdaScriptSaveWriter()
        writer.path = path
        writer.configurationError = errorCode
        writer.onWake = onWake
        if let url { writer.state = AdaScriptSaveStreamState(destination: url) }
        return writer
    }

    deinit {
        if let state { Task { await state.cancel() } }
    }

    func append(_ text: String) -> AdaScriptAsyncOperation {
        let operation = makeOperation()
        guard !stateLock.withLock({ didCancel }) else {
            operation.complete(.failure("cancelled", message: "Save writer was cancelled"))
            return operation
        }
        guard let state else {
            operation.complete(.failure(configurationError ?? "invalidWriter", message: "Save writer is unavailable"))
            return operation
        }
        guard text.utf8.count <= 262_144 else {
            operation.complete(.failure("chunkTooLarge", message: "Save chunks must be 256 KiB or smaller"))
            return operation
        }
        let task = Task {
            do {
                try await state.append(text)
                operation.complete(.success())
            } catch is CancellationError {
                operation.complete(.failure("cancelled", message: "Save chunk was cancelled"))
            } catch {
                operation.complete(.failure("writeFailed", message: error.localizedDescription))
            }
        }
        operation.installCancellationAction {
            task.cancel()
            Task { await state.cancel() }
        }
        return operation
    }

    func finish() -> AdaScriptAsyncOperation {
        let operation = makeOperation()
        operation.cancellationIsAdvisory = true
        guard !stateLock.withLock({ didCancel }) else {
            operation.complete(.failure("cancelled", message: "Save writer was cancelled"))
            return operation
        }
        guard let state else {
            operation.complete(.failure(configurationError ?? "invalidWriter", message: "Save writer is unavailable"))
            return operation
        }
        let path = path
        let task = Task {
            do {
                try await state.finish()
                operation.complete(.success(path, committed: true))
            } catch is CancellationError {
                operation.complete(.failure("cancelled", message: "Save commit was cancelled"))
            } catch {
                operation.complete(.failure("writeFailed", message: error.localizedDescription))
            }
        }
        operation.installCancellationAction { task.cancel() }
        return operation
    }

    func cancel() {
        stateLock.withLock { didCancel = true }
        if let state { Task { await state.cancel() } }
    }

    @GSExportableIgnore
    private func makeOperation() -> AdaScriptAsyncOperation {
        let operation = AdaScriptAsyncOperation()
        operation.onCompletion = onWake
        return operation
    }
}

private actor AdaScriptSaveStreamState {
    private enum Status {
        case open
        case committed
        case cancelled
    }

    private let destination: URL
    private let temporary: URL
    private var handle: FileHandle?
    private var status: Status = .open

    init(destination: URL) {
        self.destination = destination
        temporary = destination.deletingLastPathComponent()
            .appendingPathComponent(".ada-save-\(UUID().uuidString).tmp")
    }

    func append(_ text: String) throws {
        try Task.checkCancellation()
        guard status == .open else { throw SaveStreamError.closed }
        try openIfNeeded()
        try Task.checkCancellation()
        try handle?.write(contentsOf: Data(text.utf8))
    }

    func finish() throws {
        try Task.checkCancellation()
        guard status == .open else { throw SaveStreamError.closed }
        try openIfNeeded()
        try handle?.close()
        handle = nil
        try Task.checkCancellation()
        #if os(Windows)
            // Foundation's replaceItemAt is unavailable on Windows. A native
            // same-directory rename commits without first deleting the old save.
            let moved = temporary.path.withCString(encodedAs: UTF16.self) { source in
                destination.path.withCString(encodedAs: UTF16.self) { target in
                    MoveFileExW(source, target, DWORD(MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
                }
            }
            guard moved else { throw SaveStreamError.commitFailed(GetLastError()) }
        #elseif os(Linux)
            // Rename replaces the destination in one operation on the same filesystem.
            let result = unsafe temporary.path.withCString { source in
                unsafe destination.path.withCString { target in
                    unsafe Glibc.rename(source, target)
                }
            }
            guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        #else
            let fileManager = FileManager.default
            if fileManager.fileExists(atPath: destination.path) {
                _ = try fileManager.replaceItemAt(destination, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: destination)
            }
        #endif
        status = .committed
    }

    func cancel() {
        guard status == .open else {
            return
        }
        try? handle?.close()
        handle = nil
        try? FileManager.default.removeItem(at: temporary)
        status = .cancelled
    }

    private func openIfNeeded() throws {
        guard handle == nil else {
            return
        }
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard fileManager.createFile(atPath: temporary.path, contents: nil) else {
            throw SaveStreamError.cannotCreateTemporaryFile
        }
        handle = try FileHandle(forWritingTo: temporary)
    }
}

private enum SaveStreamError: Error {
    case cannotCreateTemporaryFile
    case closed
    #if os(Windows)
        case commitFailed(DWORD)
    #endif
}
