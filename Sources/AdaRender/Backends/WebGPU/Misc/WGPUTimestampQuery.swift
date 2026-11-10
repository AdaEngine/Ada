//
//  WGPUTimestampQuery.swift
//  AdaEngine
//

#if WEBGPU_ENABLED && canImport(WebGPU) && !WASM
    import Foundation
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    /// With `ADAENGINE_GPU_TIMINGS=1`, sums the GPU time of every command buffer by label and prints
    /// `GPU_LEDGER` lines every second: milliseconds of GPU work per second of wall time (the share
    /// of time the single queue was busy) and the split by label.
    enum WGPUGPUTimeLedger {
        private struct Entry {
            var count = 0
            var sum: Double = 0
            var maximum: Double = 0
        }
        private struct State {
            var entries: [String: Entry] = [:]
            var start = ContinuousClock.now
        }
        private static let state = Mutex(State())

        static func record(_ name: String, seconds: Double) {
            let report: String? = state.withLock { state in
                var entry = state.entries[name] ?? Entry()
                entry.count += 1
                entry.sum += seconds * 1000
                entry.maximum = max(entry.maximum, seconds * 1000)
                state.entries[name] = entry
                let now = ContinuousClock.now
                let elapsed = state.start.duration(to: now)
                guard elapsed >= .seconds(1) else { return nil }
                let wall = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
                let total = state.entries.values.reduce(0) { $0 + $1.sum }
                var lines = [String(format: "GPU_LEDGER busy=%.0f ms/s over %.1f s", total / wall, wall)]
                for (label, value) in state.entries.sorted(by: { $0.value.sum > $1.value.sum }) {
                    let row = String(format: "GPU_LEDGER   %7.2f ms/s  avg %6.3f ms  max %7.2f ms  n=%5d  ",
                                     value.sum / wall, value.sum / Double(value.count), value.maximum, value.count)
                    lines.append(row + label)
                }
                state.entries.removeAll(keepingCapacity: true)
                state.start = now
                return lines.joined(separator: "\n") + "\n"
            }
            if let report {
                try? FileHandle.standardOutput.write(contentsOf: Data(report.utf8))
            }
        }
    }

    /// Opt-in GPU execution timing for native WebGPU command buffers.
    ///
    /// `ADAENGINE_GPU_TIMINGS=1` requests the timestamp-query feature at device creation. Each command
    /// buffer then writes a timestamp when it is created and another when it is committed, and
    /// `addCompletedTimingHandler` receives the difference. Timestamps cost a query set and two small
    /// buffers per command buffer, so they stay off unless profiling asks for them.
    final class WGPUTimestampQuery: @unchecked Sendable {
        static let isRequested = ProcessInfo.processInfo.environment["ADAENGINE_GPU_TIMINGS"] == "1"

        // Immutable Dawn handles; every use takes `webGPUDeviceLock`.
        private let querySet: WebGPU.GPUQuerySet
        private let resolveBuffer: WebGPU.GPUBuffer
        private let readbackBuffer: WebGPU.GPUBuffer
        private let instance: WebGPU.GPUInstance?
        private static let byteCount = 2 * MemoryLayout<UInt64>.size

        /// Creates the query and writes the start timestamp, or returns nil when timing is off or unsupported.
        /// Call under `webGPUDeviceLock`.
        init?(device: WebGPU.GPUDevice, encoder: WebGPU.GPUCommandEncoder, instance: WebGPU.GPUInstance?) {
            guard Self.isRequested, device.hasFeature(feature: .timestampQuery) else {
                return nil
            }
            querySet = device.createQuerySet(descriptor: WebGPU.GPUQuerySetDescriptor(label: "GPU timing", type: .timestamp, count: 2))
            guard
                let resolve = device.createBuffer(descriptor: WebGPU.GPUBufferDescriptor(usage: [.queryResolve, .copySrc], size: UInt64(Self.byteCount))),
                let readback = device.createBuffer(descriptor: WebGPU.GPUBufferDescriptor(usage: [.mapRead, .copyDst], size: UInt64(Self.byteCount)))
            else {
                querySet.destroy()
                return nil
            }
            resolveBuffer = resolve
            readbackBuffer = readback
            self.instance = instance
            encoder.writeTimestamp(querySet: querySet, queryIndex: 0)
        }

        /// Writes the end timestamp and copies both into the readback buffer. Call under `webGPUDeviceLock`.
        func encodeEnd(on encoder: WebGPU.GPUCommandEncoder) {
            encoder.writeTimestamp(querySet: querySet, queryIndex: 1)
            encoder.resolveQuerySet(querySet: querySet, firstQuery: 0, queryCount: 2, destination: resolveBuffer, destinationOffset: 0)
            encoder.copyBufferToBuffer(
                source: resolveBuffer,
                sourceOffset: 0,
                destination: readbackBuffer,
                destinationOffset: 0,
                size: UInt64(Self.byteCount)
            )
        }

        /// Reads the elapsed seconds after the command buffer finished, then releases the query resources.
        func readElapsedSeconds() async -> Double? {
            let result = Mutex<Double??>(nil)
            let readback = readbackBuffer
            let info = WebGPU.GPUBufferMapCallbackInfo(
                mode: .allowProcessEvents,
                callback: { status, _ in
                    var seconds: Double?
                    if status == .success, let pointer = unsafe readback.getConstMappedRange(offset: 0, size: Self.byteCount) {
                        let start = unsafe pointer.load(as: UInt64.self)
                        let end = unsafe pointer.load(fromByteOffset: MemoryLayout<UInt64>.size, as: UInt64.self)
                        // Dawn reports nanoseconds; a reset or reordered pair yields no sample.
                        seconds = end > start ? Double(end - start) / 1_000_000_000 : nil
                        readback.unmap()
                    }
                    result.withLock { $0 = .some(seconds) }
                }
            )
            webGPUDeviceLock.withLock { _ in
                info.withWGPUStruct { native in
                    native.callback = { status, message, userdata, _ in
                        guard let userdata else { return }
                        let callback = Unmanaged<AnyObject>.fromOpaque(userdata).takeRetainedValue() as! WebGPU.GPUBufferMapCallback
                        callback(status, message.toString)
                    }
                    _ = readback.mapAsync(mode: .read, offset: 0, size: Self.byteCount, callbackInfo: native)
                }
            }
            let deadline = ContinuousClock.now + .seconds(5)
            var seconds: Double?
            while ContinuousClock.now < deadline {
                webGPUDeviceLock.withLock { _ in instance?.processEvents() }
                if let value = result.withLock({ $0 }) {
                    seconds = value
                    break
                }
                await Task.yield()
            }
            webGPUDeviceLock.withLock { _ in
                querySet.destroy()
                resolveBuffer.destroy()
                readbackBuffer.destroy()
            }
            return seconds
        }
    }
#endif
