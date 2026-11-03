#if canImport(WebGPU) && !os(WASI) && !os(Android)
@_spi(Internal) @testable import AdaRender
import Foundation
import Synchronization
import Testing

@MainActor
@Suite("Native WebGPU command completion", .serialized)
struct WGPUCommandCompletionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func deliversOnceAndAllowsHandlersToSubmitMoreWork() async throws {
        let device = try WebGPURenderBackend.createBackend().createLocalRenderDevice()
        let queue = device.createCommandQueue()
        let calls = Mutex(0)
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        let first = queue.makeCommandBuffer()
        let source = device.createBuffer(label: "Completion source", length: 65536, options: .storageShared)
        let destination = device.createBuffer(label: "Completion destination", length: 65536, options: .storageShared)
        var values = [UInt32](repeating: 0xdecafbad, count: 16384)
        source.setElements(&values)
        let copy = first.beginBlitPass(.init())
        for _ in 0..<128 {
            copy.copyBufferToBuffer(source: source, sourceOffset: 0, destination: destination, destinationOffset: 0, size: 65536)
        }
        copy.endBlitPass()
        first.addCompletedHandler {
            calls.withLock { $0 += 1 }
            // This would deadlock if handlers ran inside the native device-lock scope.
            let next = device.createCommandQueue().makeCommandBuffer()
            next.addCompletedHandler {
                calls.withLock { $0 += 1 }
                continuation.yield(())
                continuation.finish()
            }
            next.commit()
        }
        first.commit()
        let completed = try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in stream { return true }
                return false
            }
            group.addTask {
                try await Task.sleep(for: .seconds(5))
                return false
            }
            let result = try await group.next() ?? false
            group.cancelAll()
            return result
        }
        try #require(completed, "Native queue completion must not require an application event pump")
        #expect(calls.withLock { $0 } == 2)
        let data = try await destination.readData()
        #expect(data.prefix(4) == Data([0xad, 0xfb, 0xca, 0xde]))
    }
}
#endif
