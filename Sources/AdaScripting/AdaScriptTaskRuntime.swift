import Foundation
import Gravity

/// Owns VM-rooted AdaScript tasks and resumes them only at script dispatch points.
@GSExportable("AdaTaskRuntime")
// Task records are accessed under AdaScriptRuntimeCoordinator; native workers
// only invoke the immutable wake callback and never enter the VM.
final class AdaScriptTaskRuntime: @unchecked Sendable {
    @GSExportableIgnore
    private struct TaskEntry {
        let ownerID: String
        let parentID: Int?
        let traceID: String
        let value: GSValue
        let nativeOperation: AdaScriptAsyncOperation?
    }

    @GSExportableIgnore
    private weak var virtualMachine: GravityVirtualMachine?

    @GSExportableIgnore
    private var tasks: [Int: TaskEntry] = [:]

    @GSExportableIgnore
    var currentOwnerID: String?

    @GSExportableIgnore
    private var currentTaskID: Int?

    @GSExportableIgnore
    private var lastResumedID = 0

    @GSExportableIgnore
    private(set) var isVMAborted = false

    @GSExportableIgnore
    private var nextIdentifier = 1

    @GSExportableIgnore
    private var reportDiagnostic: @Sendable (String) -> Void = { _ in }

    @GSExportableIgnore
    private var suspensionPolicy: AdaScriptSuspensionPolicy?

    @GSExportableIgnore
    private let maximumTasks = 1024

    @GSExportableIgnore
    private let maximumResumesPerDispatch = 256

    @GSExportableIgnore
    var onWake: (@Sendable () -> Void)?

    @GSExportableIgnore
    static func make(
        virtualMachine: GravityVirtualMachine,
        reportDiagnostic: @escaping @Sendable (String) -> Void,
        suspensionPolicy: AdaScriptSuspensionPolicy
    ) -> AdaScriptTaskRuntime {
        let runtime = AdaScriptTaskRuntime()
        runtime.virtualMachine = virtualMachine
        runtime.reportDiagnostic = reportDiagnostic
        runtime.suspensionPolicy = suspensionPolicy
        return runtime
    }

    func validateCapture(_ values: GSValue) -> Bool {
        guard values.isList, let suspensionPolicy else {
            reportDiagnostic("ADASCRIPT_NONSENDABLE invalid suspension capture")
            return false
        }
        for value in values.toList {
            if let reason = suspensionPolicy.validate(value) {
                reportDiagnostic("ADASCRIPT_NONSENDABLE \(reason)")
                return false
            }
        }
        return true
    }

    /// Registers a task; script execution begins at the next dispatch point.
    func start(_ task: GSValue) -> Int {
        guard !isVMAborted else {
            reportDiagnostic("ADASCRIPT_VM_ABORTED reload the script module before starting another task")
            return -1
        }
        guard task.hasMethod(named: "resume") else {
            reportDiagnostic("Tasks.start requires an async task")
            return -1
        }
        guard let ownerID = currentOwnerID else {
            reportDiagnostic("Tasks.start requires a live lifecycle owner")
            return -1
        }
        guard tasks.count < maximumTasks, let virtualMachine else {
            reportDiagnostic("AdaScript task limit exceeded")
            return -1
        }
        let identifier = nextIdentifier
        nextIdentifier += 1
        let traceID = currentTaskID.flatMap { tasks[$0]?.traceID } ?? UUID().uuidString
        let nativeOperation = task.callMethod(named: "nativeOperation", with: [])?.toObjectOf(AdaScriptAsyncOperation.self)
        tasks[identifier] = TaskEntry(
            ownerID: ownerID,
            parentID: currentTaskID,
            traceID: traceID,
            value: task,
            nativeOperation: nativeOperation
        )
        virtualMachine.setValue(task, forKey: rootName(identifier))
        onWake?()
        return identifier
    }

    func wake() {
        onWake?()
    }

    @GSExportableIgnore
    func pump(onlyWorld worldID: String? = nil) {
        guard !isVMAborted else {
            return
        }
        guard let virtualMachine else {
            return
        }
        let sorted = tasks.keys.sorted().filter { identifier in
            guard let worldID else {
                return true
            }
            return tasks[identifier]?.ownerID.hasPrefix(worldID + ":system:") == true
        }
        let identifiers = Array((sorted.filter { $0 > lastResumedID } + sorted.filter { $0 <= lastResumedID }).prefix(maximumResumesPerDispatch))
        if let last = identifiers.last { lastResumedID = last }
        for identifier in identifiers {
            guard let entry = tasks[identifier] else { continue }
            let previousOwner = currentOwnerID
            let previousTask = currentTaskID
            currentOwnerID = entry.ownerID
            currentTaskID = identifier
            defer {
                currentOwnerID = previousOwner
                currentTaskID = previousTask
            }
            let task = entry.value
            _ = task.callMethod(named: "resume", with: [])
            guard let outcome = task.callMethod(named: "isComplete", with: []), outcome.isBool else {
                quarantineVM(after: identifier, entry: entry)
                return
            }
            if outcome.toBoolean {
                if task.callMethod(named: "didFail", with: [])?.toBoolean == true {
                    quarantineVM(after: identifier, entry: entry)
                    return
                }
                cancelDescendants(of: identifier, in: virtualMachine)
                finish(identifier, in: virtualMachine)
                onWake?()
            }
        }
    }

    @GSExportableIgnore
    func cancelAll() {
        guard let virtualMachine else {
            tasks.removeAll()
            return
        }
        for identifier in tasks.keys.sorted() {
            _ = tasks[identifier]?.value.callMethod(named: "cancel", with: [])
            finish(identifier, in: virtualMachine)
        }
    }

    @GSExportableIgnore
    var activeTaskCount: Int { tasks.count }

    @GSExportableIgnore
    func cancel(ownerID: String) {
        guard let virtualMachine else {
            return
        }
        for identifier in tasks.keys.sorted() where tasks[identifier]?.ownerID == ownerID {
            _ = tasks[identifier]?.value.callMethod(named: "cancel", with: [])
            finish(identifier, in: virtualMachine)
        }
    }

    @GSExportableIgnore
    func cancel(worldID: String) {
        guard let virtualMachine else {
            return
        }
        for identifier in tasks.keys.sorted() where tasks[identifier]?.ownerID.hasPrefix(worldID + ":system:") == true {
            _ = tasks[identifier]?.value.callMethod(named: "cancel", with: [])
            finish(identifier, in: virtualMachine)
        }
    }

    @GSExportableIgnore
    private func finish(_ identifier: Int, in virtualMachine: GravityVirtualMachine) {
        tasks.removeValue(forKey: identifier)
        virtualMachine.setValue(GSValue(nullIn: virtualMachine), forKey: rootName(identifier))
    }

    @GSExportableIgnore
    private func cancelDescendants(of parentID: Int, in virtualMachine: GravityVirtualMachine) {
        let children = tasks.keys.sorted().filter { tasks[$0]?.parentID == parentID }
        for identifier in children {
            cancelDescendants(of: identifier, in: virtualMachine)
            _ = tasks[identifier]?.value.callMethod(named: "cancel", with: [])
            finish(identifier, in: virtualMachine)
        }
    }

    @GSExportableIgnore
    private func rootName(_ identifier: Int) -> String {
        "__ada_live_task_\(identifier)"
    }

    @GSExportableIgnore
    private func taskDescription(_ identifier: Int, entry: TaskEntry) -> String {
        "id=\(identifier) parent=\(entry.parentID.map { String($0) } ?? "none") owner=\(entry.ownerID) trace=\(entry.traceID)"
    }

    @GSExportableIgnore
    private func quarantineVM(after identifier: Int, entry: TaskEntry) {
        isVMAborted = true
        for task in tasks.values {
            _ = task.nativeOperation?.cancel()
        }
        tasks.removeAll()
        reportDiagnostic("ADASCRIPT_VM_ABORTED \(taskDescription(identifier, entry: entry)); reload the script module")
        onWake?()
    }
}

enum AdaScriptTaskPrelude {
    static let source = """
    extern var __adaTasks;
    extern var __adaAsync;

    class __AdaTask {
        var fiber = null;
        var value = null;
        var done = false;
        var cancelled = false;
        var started = false;
        var operation = null;

        func resume() {
            if (done || cancelled) { return true; }
            if (fiber == null) { return false; }
            fiber.try();
            if (fiber.isDone()) { done = true; }
            return done;
        }

        func complete(value) {
            if (done || cancelled) { return false; }
            if (!__adaTasks.validateCapture([value])) { cancel(); return false; }
            self.value = value;
            done = true;
            __adaTasks.wake();
            return true;
        }

        func capture(values) {
            if (!__adaTasks.validateCapture(values)) { cancel(); }
        }

        func cancel() {
            if (done || cancelled) { return false; }
            cancelled = true;
            if (operation != null) { operation.cancel(); }
            __adaTasks.wake();
            return true;
        }

        func status() {
            if (cancelled) { return "cancelled"; }
            if (didFail()) { return "failed"; }
            if (done) { return "completed"; }
            if (started) { return "running"; }
            return "created";
        }

        func isComplete() {
            return done || cancelled;
        }

        func didFail() {
            return fiber != null && fiber.status() == 1;
        }

        func nativeOperation() {
            return operation;
        }
    }

    class Tasks {
        static func start(task) {
            if (task.cancelled) { return task; }
            if (!task.started) {
                var identifier = __adaTasks.start(task);
                if (identifier < 0) { task.cancel(); return task; }
                task.started = true;
            }
            return task;
        }

        static func promise() {
            return __AdaTask();
        }

        static func nextFrame() {
            var task = __AdaTask();
            task.fiber = Fiber.create({ task.done = true; });
            return task;
        }
    }

    func __adaTaskFromOperation(operation) {
        var task = __AdaTask();
        task.operation = operation;
        task.fiber = Fiber.create({
            while (!operation.isDone()) { Fiber.yield(); }
            task.value = operation.result();
            task.done = true;
        });
        return task;
    }

    class Time {
        static func sleep(seconds) {
            return __adaTaskFromOperation(__adaAsync.sleep(seconds));
        }

        static func sleepRealTime(seconds) {
            return __adaTaskFromOperation(__adaAsync.sleepRealTime(seconds));
        }
    }

    class Saves {
        static func writeAsync(path, text) {
            return __adaTaskFromOperation(__adaAsync.writeText(path, text));
        }

        static func begin(path) {
            var writer = __AdaSaveWriter();
            writer.native = __adaAsync.beginSave(path);
            return writer;
        }
    }

    class __AdaSaveWriter {
        var native = null;

        func appendAsync(chunk) {
            return __adaTaskFromOperation(native.append(chunk));
        }

        func finishAsync() {
            return __adaTaskFromOperation(native.finish());
        }

        func cancel() { native.cancel(); }
    }

    func __adaAwait(task) {
        Tasks.start(task);
        while (!task.done && !task.cancelled) {
            Fiber.yield();
        }
        if (task.cancelled) { return null; }
        return task.value;
    }
    """
}
