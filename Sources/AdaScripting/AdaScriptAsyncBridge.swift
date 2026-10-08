@_spi(AdaEngine) import AdaAssets
import Foundation
import Gravity

@GSExportable("AdaAsyncResult")
// Fields are set before publication to a worker or the VM and never mutated afterward.
final class AdaScriptAsyncResult: @unchecked Sendable, AdaScriptSuspensionSafeBridge {
    @GSExportableIgnore
    private var successful = false

    @GSExportableIgnore
    private var output = ""

    @GSExportableIgnore
    private var code = ""

    @GSExportableIgnore
    private var detail = ""

    @GSExportableIgnore
    private var didCommit = false

    func isSuccess() -> Bool { successful }
    func value() -> String { output }
    func errorCode() -> String { code }
    func message() -> String { detail }
    func committed() -> Bool { didCommit }

    @GSExportableIgnore
    static func success(_ value: String = "", committed: Bool = false) -> AdaScriptAsyncResult {
        let result = AdaScriptAsyncResult()
        result.successful = true
        result.output = value
        result.didCommit = committed
        return result
    }

    @GSExportableIgnore
    static func failure(_ code: String, message: String) -> AdaScriptAsyncResult {
        let result = AdaScriptAsyncResult()
        result.code = code
        result.detail = message
        return result
    }
}

@GSExportable("AdaAsyncOperation")
// Completion state and the cancellation callback are protected by `lock`.
final class AdaScriptAsyncOperation: @unchecked Sendable, AdaScriptSuspensionSafeBridge {
    @GSExportableIgnore
    private let lock = NSLock()

    @GSExportableIgnore
    private var completedResult: AdaScriptAsyncResult?

    @GSExportableIgnore
    var onCompletion: (@Sendable () -> Void)?

    @GSExportableIgnore
    private var cancelAction: (@Sendable () -> Void)?

    @GSExportableIgnore
    var cancellationIsAdvisory = false

    func isDone() -> Bool { lock.withLock { completedResult != nil } }

    func result() -> AdaScriptAsyncResult {
        lock.withLock { completedResult } ?? .failure("notReady", message: "Async operation is still running")
    }

    func cancel() -> Bool {
        let action = lock.withLock { completedResult == nil ? cancelAction : nil }
        guard let action else {
            return false
        }
        action()
        if !cancellationIsAdvisory {
            complete(.failure("cancelled", message: "Async operation was cancelled"))
        }
        return true
    }

    @GSExportableIgnore
    func installCancellationAction(_ action: @escaping @Sendable () -> Void) {
        lock.withLock {
            if completedResult == nil { cancelAction = action }
        }
    }

    @GSExportableIgnore
    func complete(_ result: AdaScriptAsyncResult) {
        let accepted = lock.withLock { () -> Bool in
            guard completedResult == nil else {
                return false
            }
            completedResult = result
            cancelAction = nil
            return true
        }
        if accepted { onCompletion?() }
    }
}

/// Host operations return detached results; completion never enters the VM.
@GSExportable("AdaAsyncHost")
// Timer and writer registries are entered only under AdaScriptRuntimeCoordinator;
// workers mutate their separate, lock-protected operation objects.
final class AdaScriptAsyncHost: @unchecked Sendable {
    @GSExportableIgnore
    private final class WeakSaveWriter {
        weak var value: AdaScriptSaveWriter?

        init(_ value: AdaScriptSaveWriter) { self.value = value }
    }

    @GSExportableIgnore
    private struct GameTimer {
        let operation: AdaScriptAsyncOperation
        let worldID: String
        var remaining: Double
    }

    @GSExportableIgnore
    private var gameTimers: [GameTimer] = []

    @GSExportableIgnore
    private var writersByOwner: [String: [WeakSaveWriter]] = [:]

    @GSExportableIgnore
    var onWake: (@Sendable () -> Void)?

    @GSExportableIgnore
    var ownerProvider: (@Sendable () -> String?)?

    func sleep(_ seconds: Double) -> AdaScriptAsyncOperation {
        let operation = AdaScriptAsyncOperation()
        operation.onCompletion = onWake
        guard seconds.isFinite, seconds >= 0 else {
            operation.complete(.failure("invalidDuration", message: "Timer duration must be finite and nonnegative"))
            return operation
        }
        guard let ownerID = ownerProvider?(), ownerID.hasPrefix("world:"),
              let boundary = ownerID.range(of: ":system:") else {
            operation.complete(.failure("missingGameClock", message: "Time.sleep requires a world-owned task"))
            return operation
        }
        let worldID = String(ownerID[..<boundary.lowerBound])
        gameTimers.append(GameTimer(operation: operation, worldID: worldID, remaining: seconds))
        operation.installCancellationAction { [weak self, weak operation] in
            guard let operation else {
                return
            }
            self?.gameTimers.removeAll(where: { $0.operation === operation })
        }
        return operation
    }

    func sleepRealTime(_ seconds: Double) -> AdaScriptAsyncOperation {
        let operation = AdaScriptAsyncOperation()
        operation.onCompletion = onWake
        guard seconds.isFinite, seconds >= 0 else {
            operation.complete(.failure("invalidDuration", message: "Timer duration must be finite and nonnegative"))
            return operation
        }
        let task = Task {
            if Task.isCancelled {
                operation.complete(.failure("cancelled", message: "Real-time timer was cancelled"))
                return
            }
            do {
                try await Task.sleep(for: .seconds(seconds))
                operation.complete(.success())
            } catch {
                operation.complete(.failure("cancelled", message: "Real-time timer was cancelled"))
            }
        }
        operation.installCancellationAction { task.cancel() }
        return operation
    }

    func writeText(_ path: String, _ text: String) -> AdaScriptAsyncOperation {
        let operation = AdaScriptAsyncOperation()
        operation.onCompletion = onWake
        operation.cancellationIsAdvisory = true
        #if WASM
            operation.complete(.failure("unsupportedOperation", message: "Background file saves are unavailable in the current WebAssembly filesystem"))
            return operation
        #else
        guard let url = writableURL(for: path) else {
            operation.complete(.failure("invalidPath", message: "Save path must remain within a writable virtual root"))
            return operation
        }
        let task = Task {
            do {
                try Task.checkCancellation()
                let data = Data(text.utf8)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
                operation.complete(.success(path, committed: true))
            } catch {
                operation.complete(.failure("writeFailed", message: error.localizedDescription))
            }
        }
        operation.installCancellationAction { task.cancel() }
        return operation
        #endif
    }

    func beginSave(_ path: String) -> AdaScriptSaveWriter {
        let writer: AdaScriptSaveWriter
        #if WASM
            writer = AdaScriptSaveWriter.make(
                path: path,
                url: nil,
                errorCode: "unsupportedOperation",
                onWake: onWake
            )
        #else
            let url = writableURL(for: path)
            writer = AdaScriptSaveWriter.make(
                path: path,
                url: url,
                errorCode: url == nil ? "invalidPath" : nil,
                onWake: onWake
            )
        #endif
        if let ownerID = ownerProvider?() {
            writersByOwner[ownerID, default: []].append(WeakSaveWriter(writer))
        }
        return writer
    }

    @GSExportableIgnore
    private func writableURL(for path: String) -> URL? {
        guard path.hasPrefix("@user://") || path.hasPrefix("@cache://"),
              !path.split(separator: "/").contains("..") else {
            return nil
        }
        let url = AssetsManager.resolveAssetURL(at: path)
        let virtualRoot = path.hasPrefix("@user://") ? "@user://" : "@cache://"
        let root = AssetsManager.resolveAssetURL(at: virtualRoot).standardizedFileURL.path
        guard url.standardizedFileURL.path.hasPrefix(root + "/") else {
            return nil
        }
        let resolvedRoot = URL(fileURLWithPath: root).resolvingSymlinksInPath().standardizedFileURL.path
        let resolvedParent = url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        guard resolvedParent == resolvedRoot || resolvedParent.hasPrefix(resolvedRoot + "/") else {
            return nil
        }
        return url
    }

    @GSExportableIgnore
    func advanceGameTime(by deltaTime: Double, forWorld worldID: String) {
        guard deltaTime.isFinite, deltaTime > 0 else {
            return
        }
        for index in gameTimers.indices where gameTimers[index].worldID == worldID {
            gameTimers[index].remaining -= deltaTime
        }
        for timer in gameTimers where timer.worldID == worldID && timer.remaining <= 0 {
            timer.operation.complete(.success())
        }
        gameTimers.removeAll(where: { $0.worldID == worldID && $0.remaining <= 0 })
    }

    @GSExportableIgnore
    func cancelAll() {
        for timer in gameTimers {
            timer.operation.complete(.failure("cancelled", message: "Timer owner was destroyed"))
        }
        gameTimers.removeAll()
        for writers in writersByOwner.values {
            for writer in writers { writer.value?.cancel() }
        }
        writersByOwner.removeAll()
    }

    @GSExportableIgnore
    func cancelGameTimers(forWorld worldID: String) {
        for timer in gameTimers where timer.worldID == worldID {
            timer.operation.complete(.failure("cancelled", message: "World was destroyed"))
        }
        gameTimers.removeAll(where: { $0.worldID == worldID })
        let owners = writersByOwner.keys.filter { $0.hasPrefix(worldID + ":system:") }
        for ownerID in owners {
            cancelSaveWriters(forOwner: ownerID)
        }
    }

    @GSExportableIgnore
    func cancelSaveWriters(forOwner ownerID: String) {
        for writer in writersByOwner.removeValue(forKey: ownerID) ?? [] {
            writer.value?.cancel()
        }
    }
}
