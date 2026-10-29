#if WEBGPU_ENABLED && canImport(WebGPU) && !WASM
import Synchronization
@unsafe @preconcurrency import WebGPU

/// Retains the submission until the queue has finished. A submitted frame is not
/// ready for capture/presentation or texture-pool reuse until this fence signals.
final class WGPUCommandCompletion: @unchecked Sendable {
    let instance: WebGPU.GPUInstance?
    let command: WebGPU.GPUCommandBuffer
    let handlers: [@Sendable () -> Void]
    let finished = Mutex(false)

    init(instance: WebGPU.GPUInstance?, command: WebGPU.GPUCommandBuffer, handlers: [@Sendable () -> Void]) {
        self.instance = instance
        self.command = command
        self.handlers = handlers
    }

    func complete() {
        let first = finished.withLock { value in
            if value { return false }
            value = true
            return true
        }
        // ProcessEvents runs under the device lock. User handlers may encode new
        // work, so deliver them after returning from the native callback.
        if first { Task.detached { [self] in handlers.forEach { $0() } } }
    }

    func pumpEvents() {
        guard instance != nil else { return }
        Task.detached { [self] in
            let deadline = ContinuousClock.now + .seconds(30)
            while !finished.withLock({ $0 }), ContinuousClock.now < deadline {
                webGPUDeviceLock.withLock { _ in instance?.processEvents() }
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
    }
}
#endif
