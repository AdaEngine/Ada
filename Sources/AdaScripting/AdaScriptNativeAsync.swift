#if canImport(GravityAOT)
import Foundation
import GravityAOT

/// Weak ownership lets plugin teardown cancel live owners without keeping removed
/// scriptable objects alive. Each owner resumes only inside its declared callback.
final class NativeAsyncRegistry: @unchecked Sendable {
    private final class Entry {
        weak var runtime: NativeAsyncRuntime?
        init(_ runtime: NativeAsyncRuntime) { self.runtime = runtime }
    }
    private let lock = NSLock()
    private var entries: [Entry] = []
    func register(_ runtime: NativeAsyncRuntime) {
        lock.withLock {
            entries.removeAll { $0.runtime == nil }
            entries.append(Entry(runtime))
        }
    }
    func cancelAll(stopOwners: Bool = true) {
        let runtimes = lock.withLock { entries.compactMap(\.runtime) }
        for runtime in runtimes { runtime.cancelAll(stopOwner: stopOwners) }
    }
}

private final class NativeAsyncClock: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: UInt64 = 0
    private var seconds: Double = 0
    var now: (UInt64, Double) { lock.withLock { (frame, seconds) } }
    func advance(_ delta: Double) {
        lock.withLock {
            frame &+= 1
            if delta.isFinite { seconds += max(0, delta) }
        }
    }
}

private protocol NativePendingOperation: NativeSuspensionSafeHostObject {
    var isDone: Bool { get }
    func cancel()
}

/// All scheduling and clock state is synchronized. Native code itself executes
/// under NativeModule's lock; workers publish detached results only.
final class NativeAsyncRuntime: NativeHostObject, @unchecked Sendable {
    private let module: NativeModule
    private let lock = NSLock()
    private let clock = NativeAsyncClock()
    private var tasks: [UInt: NativeTask] = [:]
    private var operations: [any NativePendingOperation] = []
    private var active = true
    private var resumeOffset = 0
    init(module: NativeModule, registry: NativeAsyncRegistry? = nil) {
        self.module = module
        registry?.register(self)
    }
    deinit { cancelAll() }
    var globals: [String: NativeValue] {
        ["Tasks": .host(self), "Time": .host(self), "__adaTaskFromOperation": .host(self)]
    }
    func advance(deltaTime: Double) {
        clock.advance(deltaTime)
        lock.withLock { operations.removeAll { $0.isDone } }
    }
    func adopt(_ value: NativeValue) throws {
        guard case .task(let task) = value else { return }
        try lock.withLock {
            guard active, tasks[task.identifier] != nil || tasks.count < 1024 else {
                throw AdaScriptError.invalidManifest("Native async owner is stopped or its task limit was reached")
            }
            tasks[task.identifier] = task
        }
    }
    func resume(receiver: NativeInstance, bindings: [String: NativeValue], globals: [String: NativeValue], recorder: NativeDiagnostics) {
        let pending = lock.withLock { () -> [NativeTask] in
            let ordered = tasks.values.sorted { $0.identifier < $1.identifier }
            guard !ordered.isEmpty else {
                return []
            }
            let start = resumeOffset % ordered.count
            let count = min(256, ordered.count)
            resumeOffset = (start + count) % ordered.count
            return (0..<count).map { ordered[(start + $0) % ordered.count] }
        }
        for task in pending {
            do {
                switch try module.poll(task, globals: globals, receiver: receiver, bindings: bindings) {
                case .pending: continue
                case .completed, .cancelled: break
                }
            } catch {
                recorder.append("Native async task failed: \(error)")
                try? module.cancel(task)
            }
            _ = lock.withLock { tasks.removeValue(forKey: task.identifier) }
        }
    }
    func cancelAll(stopOwner: Bool = true) {
        let pending = lock.withLock { () -> ([NativeTask], [any NativePendingOperation]) in
            if stopOwner { active = false }
            let pending = (Array(tasks.values), operations)
            tasks.removeAll(); operations.removeAll()
            return pending
        }
        for task in pending.0 { try? module.cancel(task) }
        for operation in pending.1 { operation.cancel() }
    }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        guard lock.withLock({ active }) else { throw AdaScriptError.invalidManifest("Native async owner is stopped") }
        switch method {
        case "start" where arguments.count == 1:
            try adopt(arguments[0])
            if case .task(let task) = arguments[0] { try module.start(task) }
            return arguments[0]
        case "promise" where arguments.isEmpty: return .task(try module.makePromise())
        case "nextFrame" where arguments.isEmpty:
            let now = clock.now
            let operation = NativeClockOperation(clock: clock, frame: now.0 &+ 1, seconds: nil)
            track(operation); return .host(operation)
        case "sleep", "sleepRealTime":
            guard arguments.count == 1 else {
                return nil
            }
            let seconds: Double
            switch arguments[0] {
            case .integer(let value): seconds = Double(value)
            case .double(let value): seconds = value
            default: return nil
            }
            guard seconds.isFinite, seconds >= 0, seconds <= Double(Int64.max) / 1_000_000_000 else { throw AdaScriptError.invalidManifest("Timer duration must be finite and nonnegative") }
            if method == "sleepRealTime" {
                let operation = NativeOperationHost(AdaScriptAsyncHost().sleepRealTime(seconds))
                track(operation); return .host(operation)
            }
            let operation = NativeClockOperation(clock: clock, frame: nil, seconds: clock.now.1 + seconds)
            track(operation); return .host(operation)
        case "__adaTaskFromOperation" where arguments.count == 1:
            guard case .host(let operation) = arguments[0], operation is any NativePendingOperation else {
                return nil
            }
            return arguments[0]
        default: return nil
        }
    }
    private func track(_ operation: any NativePendingOperation) {
        let accepted = lock.withLock { () -> Bool in
            guard active else {
                return false
            }
            operations.append(operation); return true
        }
        if !accepted { operation.cancel() }
    }
    func track(_ operation: NativeOperationHost) { track(operation as any NativePendingOperation) }
}

private final class NativeClockOperation: NativePendingOperation, @unchecked Sendable {
    private let clock: NativeAsyncClock
    private let frame: UInt64?
    private let seconds: Double?
    private let lock = NSLock()
    private var cancelled = false
    init(clock: NativeAsyncClock, frame: UInt64?, seconds: Double?) {
        self.clock = clock; self.frame = frame; self.seconds = seconds
    }
    var isDone: Bool {
        let now = clock.now
        if lock.withLock({ cancelled }) { return true }
        if let frame { return now.0 >= frame }
        if let seconds { return now.1 >= seconds }
        return true
    }
    func cancel() { lock.withLock { cancelled = true } }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        guard arguments.isEmpty else {
            return nil
        }
        switch method {
        case "isDone", "isComplete": return .boolean(isDone)
        case "status": return .string(lock.withLock({ cancelled }) ? "cancelled" : isDone ? "completed" : "running")
        case "cancel": cancel(); return .null
        case "result" where isDone:
            if lock.withLock({ cancelled }) { throw AdaScriptError.invalidManifest("Native async operation was cancelled") }
            return frame != nil ? .null : .host(NativeAsyncResultHost(.success()))
        default: return nil
        }
    }
}

final class NativeOperationHost: NativePendingOperation, @unchecked Sendable {
    private let operation: AdaScriptAsyncOperation
    init(_ operation: AdaScriptAsyncOperation) { self.operation = operation }
    var isDone: Bool { operation.isDone() }
    func cancel() { _ = operation.cancel() }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        guard arguments.isEmpty else {
            return nil
        }
        switch method {
        case "isDone", "isComplete": return .boolean(isDone)
        case "status": return .string(isDone ? (operation.result().errorCode() == "cancelled" ? "cancelled" : "completed") : "running")
        case "cancel": return .boolean(operation.cancel())
        case "result" where isDone: return .host(NativeAsyncResultHost(operation.result()))
        default: return nil
        }
    }
}

/// AdaScriptAsyncResult is immutable after publication. This adapter preserves
/// the same result API used by the VM without executing any VM code.
private final class NativeAsyncResultHost: NativeSuspensionSafeHostObject, @unchecked Sendable {
    private let result: AdaScriptAsyncResult
    init(_ result: AdaScriptAsyncResult) { self.result = result }
    func call(_ method: String, arguments: [NativeValue]) throws -> NativeValue? {
        guard arguments.isEmpty else {
            return nil
        }
        switch method {
        case "isSuccess": return .boolean(result.isSuccess())
        case "value": return .string(result.value())
        case "errorCode": return .string(result.errorCode())
        case "message": return .string(result.message())
        case "committed": return .boolean(result.committed())
        default: return nil
        }
    }
}
#endif
