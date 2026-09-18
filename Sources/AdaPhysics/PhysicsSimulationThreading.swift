//
//  PhysicsSimulationThreading.swift
//  AdaEngine
//
//

import AdaECS
import box2d
import Foundation

#if canImport(Dispatch)
    import Dispatch
#endif

public struct PhysicsSimulationThreading: Resource, Codable, Sendable {
    public var workerCount: Int
    public var box2DWorkerCount: Int
    public var box3DWorkerCount: Int

    public init(
        workerCount: Int = Self.recommendedWorkerCount,
        box2DWorkerCount: Int? = nil,
        box3DWorkerCount: Int? = nil
    ) {
        let normalizedWorkerCount = max(1, workerCount)
        self.workerCount = normalizedWorkerCount
        self.box2DWorkerCount = max(1, box2DWorkerCount ?? normalizedWorkerCount)
        self.box3DWorkerCount = max(1, box3DWorkerCount ?? normalizedWorkerCount)
    }

    public static var recommendedWorkerCount: Int {
        #if WASM
            return 1
        #else
            let coreCount = max(1, ProcessInfo.processInfo.activeProcessorCount)
            return max(1, min(8, coreCount / 2))
        #endif
    }
}

#if canImport(Dispatch)
    final class Box2DTaskScheduler: @unchecked Sendable {
        private let workerCount: Int
        private let queues: [DispatchQueue]

        init(workerCount: Int) {
            self.workerCount = max(1, workerCount)
            self.queues = (0..<self.workerCount)
                .map {
                    DispatchQueue(
                        label: "org.adaengine.physics.box2d.worker.\($0)",
                        qos: .userInitiated
                    )
                }
        }

        func enqueueTask(
            _ task: @escaping b2TaskCallback,
            itemCount: Int32,
            minRange: Int32,
            taskContext: UnsafeMutableRawPointer?
        ) -> UnsafeMutableRawPointer? {
            let count = max(0, Int(itemCount))
            guard workerCount > 1, count > 0 else {
                unsafe task(0, itemCount, 0, taskContext)
                return nil
            }

            let suggestedTaskCount = max(1, Int(ceil(Double(count) / Double(max(1, minRange)))))
            let taskCount = min(workerCount, suggestedTaskCount)
            let handle = Box2DTaskHandle(remainingTasks: taskCount)
            let invocation = Box2DTaskInvocation(
                task: task,
                taskContext: taskContext
            )

            let baseChunk = count / taskCount
            let remainder = count % taskCount
            var startIndex = 0

            for workerIndex in 0..<taskCount {
                let chunkSize = baseChunk + (workerIndex < remainder ? 1 : 0)
                let endIndex = startIndex + chunkSize
                handle.enter()

                let currentStart = startIndex
                queues[workerIndex]
                    .async { [handle, invocation] in
                        defer { handle.leave() }
                        invocation(
                            startIndex: Int32(currentStart),
                            endIndex: Int32(endIndex),
                            workerIndex: UInt32(workerIndex)
                        )
                    }

                startIndex = endIndex
            }

            return unsafe Unmanaged.passRetained(handle).toOpaque()
        }

        func finishTask(_ task: UnsafeMutableRawPointer?) {
            guard let task = unsafe task else {
                return
            }

            let handle = unsafe Unmanaged<Box2DTaskHandle>.fromOpaque(task).takeRetainedValue()
            handle.wait()
        }
    }

    /// Box2D keeps the callback and its context alive until `finishTask` returns.
    /// The scheduler waits for every submitted closure before releasing that task handle.
    private struct Box2DTaskInvocation: @unchecked Sendable {
        let task: b2TaskCallback
        let taskContext: UnsafeMutableRawPointer?

        func callAsFunction(
            startIndex: Int32,
            endIndex: Int32,
            workerIndex: UInt32
        ) {
            unsafe task(startIndex, endIndex, workerIndex, taskContext)
        }
    }

    private final class Box2DTaskHandle: @unchecked Sendable {
        private let group = DispatchGroup()
        private let remainingTasks: Int

        init(remainingTasks: Int) {
            self.remainingTasks = remainingTasks
        }

        func enter() {
            group.enter()
        }

        func leave() {
            group.leave()
        }

        func wait() {
            guard remainingTasks > 0 else {
                return
            }
            group.wait()
        }
    }

    typealias Box2DEnqueueTaskCallback =
        @convention(c) (
            (@convention(c) (Int32, Int32, UInt32, UnsafeMutableRawPointer?) -> Void)?,
            Int32,
            Int32,
            UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?
        ) -> UnsafeMutableRawPointer?

    typealias Box2DFinishTaskCallback =
        @convention(c) (
            UnsafeMutableRawPointer?,
            UnsafeMutableRawPointer?
        ) -> Void

    let PhysicsSimulationThreading_Box2DEnqueueTask: Box2DEnqueueTaskCallback = { task, itemCount, minRange, taskContext, userContext in
        guard
            let task = unsafe task,
            let userContext = unsafe userContext
        else {
            return nil
        }

        let scheduler = unsafe Unmanaged<Box2DTaskScheduler>
            .fromOpaque(userContext)
            .takeUnretainedValue()

        return unsafe scheduler.enqueueTask(
            task,
            itemCount: itemCount,
            minRange: minRange,
            taskContext: taskContext
        )
    }

    let PhysicsSimulationThreading_Box2DFinishTask: Box2DFinishTaskCallback = { userTask, userContext in
        guard let userContext = unsafe userContext else {
            return
        }

        let scheduler = unsafe Unmanaged<Box2DTaskScheduler>
            .fromOpaque(userContext)
            .takeUnretainedValue()
        unsafe scheduler.finishTask(userTask)
    }
#endif
