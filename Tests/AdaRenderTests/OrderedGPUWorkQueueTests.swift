import Synchronization
import Testing

@testable import AdaRender

@Suite
struct OrderedGPUWorkQueueTests {
    private struct Boom: Error {}

    @Test
    func workRunsInEnqueueOrderAgainstTheAsyncCreatedContext() async {
        let log = Mutex<[Int]>([])
        let queue = OrderedGPUWorkQueue<Int>(context: { 7 }, onError: { _ in })
        for index in 0..<50 {
            queue.enqueue { context in
                // Yield so an unordered implementation interleaves.
                await Task.yield()
                log.withLock { $0.append(index * context) }
            }
        }
        await queue.drain()
        #expect(log.withLock { $0 } == (0..<50).map { $0 * 7 })
    }

    @Test
    func slotsFilledByEarlierWorkAreVisibleToLaterWork() async {
        let queue = OrderedGPUWorkQueue<Void>(context: {}, onError: { _ in })
        let slot = ResourceSlot<Int>()
        let observed = Mutex<Int?>(nil)
        queue.enqueue { _ in
            await Task.yield()
            slot.fulfill(42)
        }
        queue.enqueue { _ in observed.withLock { $0 = try? slot.get() } }
        await queue.drain()
        #expect(observed.withLock { $0 } == 42)
    }

    @Test
    func failedWorkIsReportedAndDoesNotStopLaterWork() async {
        let errors = Mutex<Int>(0)
        let ran = Mutex<Bool>(false)
        let queue = OrderedGPUWorkQueue<Void>(context: {}, onError: { _ in errors.withLock { $0 += 1 } })
        queue.enqueue { _ in throw Boom() }
        queue.enqueue { _ in ran.withLock { $0 = true } }
        await queue.drain()
        #expect(errors.withLock { $0 } == 1)
        #expect(ran.withLock { $0 })
    }

    @Test
    func contextFailureReportsOnceAndSkipsWorkWithoutHanging() async {
        let errors = Mutex<Int>(0)
        let ran = Mutex<Bool>(false)
        let queue = OrderedGPUWorkQueue<Void>(context: { throw Boom() }, onError: { _ in errors.withLock { $0 += 1 } })
        queue.enqueue { _ in ran.withLock { $0 = true } }
        queue.enqueue { _ in ran.withLock { $0 = true } }
        await queue.drain()
        #expect(errors.withLock { $0 } == 1)
        #expect(!ran.withLock { $0 })
    }

    @Test
    func unfulfilledSlotThrows() {
        let slot = ResourceSlot<Int>()
        #expect(throws: ResourceSlot<Int>.SlotError.self) { try slot.get() }
    }
}
