#if WEBGPU_ENABLED && canImport(WebGPU) && !WASM
import Dispatch
import Synchronization
@unsafe @preconcurrency import WebGPU

/// Retains the submission until the queue has finished. A submitted frame is not
/// ready for capture/presentation or texture-pool reuse until this fence signals.
final class WGPUCommandCompletion: @unchecked Sendable {
    // Keep the instance alive until its one-shot callback has delivered completion.
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
        // Dawn may invoke this inline while registering an already-complete fence,
        // under the device lock. Deliver reentrant user handlers outside that callback.
        // Immutable handles stay retained here; the gate is locked and handlers are Sendable.
        if first { Task.detached { [self] in handlers.forEach { $0() } } }
    }

    /// Some Dawn GPU futures need a checkpoint while the caller is otherwise idle
    /// (for example, awaiting a copy-only fence before starting readback). Active
    /// rendering receives spontaneous callbacks without waiting for this fallback.
    func pumpEvents(legacy: Bool) {
        guard instance != nil else { return }
        if !legacy {
            scheduleIdlePump(deadline: .now + .seconds(30))
            return
        }
        Task.detached { [self] in
            let deadline = ContinuousClock.now + .seconds(30)
            while !finished.withLock({ $0 }), ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(1))
                guard !finished.withLock({ $0 }) else { break }
                webGPUDeviceLock.withLock { _ in instance?.processEvents() }
            }
        }
    }

    private func scheduleIdlePump(deadline: ContinuousClock.Instant) {
        // The native callback owns a pending completion. A weak fallback must not
        // keep completed GPU commands and their transient resources alive for 100 ms.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self] in
            guard let self, !finished.withLock({ $0 }), ContinuousClock.now < deadline else { return }
            webGPUDeviceLock.withLock { _ in instance?.processEvents() }
            if !finished.withLock({ $0 }) { scheduleIdlePump(deadline: deadline) }
        }
    }
}
#endif
