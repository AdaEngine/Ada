//
//  OrderedGPUWorkQueue.swift
//  AdaEngine
//
//  Bridges AdaRender's synchronous resource API to SAGA's asynchronous device.
//

import Foundation
import Synchronization

/// A write-once cell for a resource created by queued work.
///
/// Work on one ``OrderedGPUWorkQueue`` runs in order, so work enqueued after the
/// creating work can read the slot synchronously.
final class ResourceSlot<Value: Sendable>: Sendable {
    enum SlotError: Error {
        case notCreated
    }

    private let storage = Mutex<Value?>(nil)

    func fulfill(_ value: Value) {
        storage.withLock { $0 = value }
    }

    func get() throws -> Value {
        guard let value = storage.withLock({ $0 }) else {
            throw SlotError.notCreated
        }
        return value
    }
}

/// Runs enqueued work strictly in submission order against a context created asynchronously.
///
/// `enqueue` never blocks, so render code can create resources and record uploads
/// synchronously while the SAGA device (an actor) is reached in the background.
/// A failure in one item is reported and does not stop later items. A failure to
/// create the context is reported once. Device work is then skipped, and cleanup still runs.
final class OrderedGPUWorkQueue<Context: Sendable>: Sendable {
    typealias Work = @Sendable (Context) async throws -> Void
    typealias Cleanup = @Sendable () async throws -> Void

    private enum Job: Sendable {
        case device(Work, onUnavailable: Cleanup?)
        case cleanup(Cleanup)
    }

    /// `ADAENGINE_SAGA_TRACE=1` writes each job's origin to stderr as it starts and ends, to find a stalled job.
    private static var traces: Bool { ProcessInfo.processInfo.environment["ADAENGINE_SAGA_TRACE"] == "1" }
    private static func trace(_ message: String) {
        try? FileHandle.standardError.write(contentsOf: Data("[SAGA queue] \(message)\n".utf8))
    }

    private final class AdjacentBatch<Item: Sendable>: Sendable {
        private let items: Mutex<[Item]?>

        init(_ first: Item) {
            items = Mutex([first])
        }

        func append(_ item: Item) -> Bool {
            items.withLock { items in
                guard let count = items?.count, count < 64 else {
                    return false
                }
                items?.append(item)
                return true
            }
        }

        func take() -> [Item] {
            items.withLock { items in
                defer { items = nil }
                return items ?? []
            }
        }
    }

    private struct State {
        var continuation: AsyncStream<(Job, String)>.Continuation?
        var adjacentBatch: (any Sendable)?
        var deferredJob: (Job, String)?
        var flushScheduled = false
        var lastRetirement: Task<Void, Never>?
        var pending = 0
        var idleWaiters: [CheckedContinuation<Void, Never>] = []

        mutating func submitDeferredJob() {
            if let deferredJob { continuation?.yield(deferredJob) }
            deferredJob = nil
        }

        mutating func flushDeferredJob() {
            submitDeferredJob()
            adjacentBatch = nil
        }
    }

    private let state = Mutex(State())
    private let onError: @Sendable (any Error) -> Void

    init(
        context: @escaping @Sendable () async throws -> Context,
        onError: @escaping @Sendable (any Error) -> Void
    ) {
        self.onError = onError
        let (stream, continuation) = AsyncStream<(Job, String)>.makeStream()
        state.withLock { $0.continuation = continuation }
        Task { [weak self] in
            var resolved: Context?
            var contextFailed = false
            let tracing = Self.traces
            var sequence = 0
            for await (job, origin) in stream {
                sequence += 1
                if tracing { Self.trace("begin \(sequence) \(origin)") }
                do {
                    switch job {
                    case let .device(work, onUnavailable):
                        if resolved == nil, !contextFailed {
                            do {
                                resolved = try await context()
                            } catch {
                                contextFailed = true
                                self?.onError(error)
                            }
                        }
                        if let resolved {
                            try await work(resolved)
                        } else {
                            try await onUnavailable?()
                        }
                    case .cleanup(let cleanup):
                        try await cleanup()
                    }
                } catch {
                    if tracing { Self.trace("FAILED \(sequence) \(origin): \(error)") }
                    self?.onError(error)
                }
                if tracing { Self.trace("end \(sequence)") }
                self?.finishOne()
            }
        }
    }

    deinit {
        state.withLock {
            $0.flushDeferredJob()
            $0.continuation?.finish()
        }
    }

    func enqueue(onUnavailable: Cleanup? = nil, _ work: @escaping Work, file: String = #fileID, line: Int = #line) {
        enqueue(.device(work, onUnavailable: onUnavailable), origin: "\(file):\(line)")
    }

    /// An allocation for a fresh buffer cannot read or modify the buffers in a deferred upload.
    /// Run it before flushing the upload, so consecutive allocations and writes can share a submission.
    func enqueueBufferAllocation(_ work: @escaping Work, file: String = #fileID, line: Int = #line) {
        state.withLock { state in
            if state.deferredJob == nil {
                // A batch already yielded by the timer is ahead of this allocation.
                state.adjacentBatch = nil
            }
            state.pending += 1
            state.continuation?.yield((.device(work, onUnavailable: nil), "\(file):\(line)"))
        }
    }

    /// Runs in queue order without creating or requiring a device.
    func enqueueCleanup(_ cleanup: @escaping Cleanup, file: String = #fileID, line: Int = #line) {
        enqueue(.cleanup(cleanup), origin: "\(file):\(line)")
    }

    /// Observes an already accepted submission while the bridge continues accepting work.
    /// Call from the ordered worker. Ordered callbacks inherit the original submission order.
    func enqueueRetirement(ordered: Bool = true, _ retirement: @escaping Cleanup) {
        state.withLock { state in
            let predecessor = ordered ? state.lastRetirement : nil
            state.pending += 1
            let task = Task { [weak self] in
                await predecessor?.value
                do {
                    try await retirement()
                } catch {
                    self?.onError(error)
                }
                self?.finishOne()
            }
            if ordered { state.lastRetirement = task }
        }
    }

    /// Coalesces neighboring items of one type until ordinary work or a size limit seals the batch.
    func enqueueAdjacent<Item: Sendable>(
        _ item: Item,
        deferUntilBoundary: Bool = false,
        submit: @escaping @Sendable (Context, [Item]) async throws -> Void,
        file: String = #fileID,
        line: Int = #line
    ) {
        let scheduleFlush = state.withLock { state -> Bool in
            if let existing = state.adjacentBatch as? AdjacentBatch<Item>, existing.append(item) {
                return false
            }
            state.flushDeferredJob()
            let batch = AdjacentBatch(item)
            state.adjacentBatch = batch
            state.pending += 1
            let job = Job.device({ context in
                try await submit(context, batch.take())
            }, onUnavailable: { _ = batch.take() })
            let entry = (job, "\(file):\(line)")
            guard deferUntilBoundary else {
                state.continuation?.yield(entry)
                return false
            }
            state.deferredJob = entry
            if state.flushScheduled {
                return false
            }
            state.flushScheduled = true
            return true
        }
        if scheduleFlush {
            // A following draw, read or drain flushes synchronously. Also deliver isolated writes.
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(2))
                self?.state.withLock {
                    $0.flushScheduled = false
                    $0.submitDeferredJob()
                }
            }
        }
    }

    private func enqueue(_ job: Job, origin: String) {
        state.withLock { state in
            state.flushDeferredJob()
            state.pending += 1
            state.continuation?.yield((job, origin))
        }
    }

    /// Suspends until all work enqueued before the call has finished.
    func drain() async {
        await withCheckedContinuation { waiter in
            let resumeNow = state.withLock { state -> Bool in
                state.flushDeferredJob()
                if state.pending == 0 {
                    return true
                }
                state.idleWaiters.append(waiter)
                return false
            }
            if resumeNow { waiter.resume() }
        }
    }

    private func finishOne() {
        let waiters = state.withLock { state -> [CheckedContinuation<Void, Never>] in
            state.pending -= 1
            guard state.pending == 0 else {
                return []
            }
            defer { state.idleWaiters.removeAll() }
            return state.idleWaiters
        }
        for waiter in waiters { waiter.resume() }
    }
}
