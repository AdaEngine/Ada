//
//  MetalBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import AdaUtils
    import Foundation
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    @_spi(Internal)
    public class WGPUBuffer: Buffer, @unchecked Sendable {
        let buffer: WebGPU.GPUBuffer
        let device: WebGPU.GPUDevice
        let instance: WebGPU.GPUInstance?
        // WebGPU buffer sizes never change. Keep draw setup off the native/JS getter.
        public let length: Int

        public var label: String? {
            didSet {
                self.buffer.setLabel(label: label ?? "")
            }
        }

        init(buffer: WebGPU.GPUBuffer, device: WebGPU.GPUDevice, instance: WebGPU.GPUInstance? = nil) {
            self.buffer = buffer
            self.length = Int(buffer.size)
            self.device = device
            self.instance = instance
        }

        private var mappedBuffer: WebGPU.GPUBuffer?

        public func contents() -> UnsafeMutableRawPointer {
            let mappedBuffer =
                webGPUDeviceLock.withLock { _ in
                    self.device.createBuffer(
                        descriptor: WebGPU.GPUBufferDescriptor(
                            usage: [.mapWrite, .copySrc],
                            size: UInt64(self.length),
                            mappedAtCreation: true
                        )
                    )
                }
                .unwrap(message: "Failed to create mapped buffer")
            self.mappedBuffer = mappedBuffer
            guard let range = unsafe mappedBuffer.getMappedRange(offset: 0, size: self.length) else {
                fatalError("Failed to get mapped buffer range")
            }
            return range
        }

        public func unmap() {
            guard let mappedBuffer = self.mappedBuffer else {
                return
            }

            let data = unsafe mappedBuffer.getMappedRange(offset: 0, size: self.length)
            webGPUDeviceLock.withLock { _ in
                unsafe device.queue.writeBuffer(
                    buffer: buffer,
                    bufferOffset: 0,
                    data: UnsafeRawBufferPointer(start: data, count: self.length)
                )
            }

            mappedBuffer.unmap()
            self.mappedBuffer = nil
        }

        public func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int, offset: Int) {
            webGPUDeviceLock.withLock { _ in
                unsafe device.queue.writeBuffer(
                    buffer: self.buffer,
                    bufferOffset: UInt64(offset),
                    data: UnsafeRawBufferPointer(start: bytes, count: byteCount)
                )
            }
        }

        public func readData() async throws -> Data {
            let created: WebGPU.GPUBuffer? = webGPUDeviceLock.withLock { _ in
                device.createBuffer(descriptor: WebGPU.GPUBufferDescriptor(usage: [.copyDst, .mapRead], size: UInt64(length)))
            }
            guard let staging = created else { throw MapError.failedToMap("Cannot allocate staging buffer") }
            let encoder = webGPUDeviceLock.withLock { _ in
                device.createCommandEncoder(descriptor: nil as WebGPU.GPUCommandEncoderDescriptor?)
            }
            encoder.copyBufferToBuffer(source: buffer, sourceOffset: 0, destination: staging, destinationOffset: 0, size: UInt64(length))
            let command: WebGPU.GPUCommandBuffer = webGPUDeviceLock.withLock { _ in
                encoder.finish(descriptor: nil as WebGPU.GPUCommandBufferDescriptor?)
            }
            webGPUDeviceLock.withLock { _ in device.queue.submit(commands: [command]) }
            #if !WASM
            if let instance {
                // Native Dawn needs event processing to advance GPU mapping,
                // even with spontaneous callbacks. Yield while the GPU works.
                let result = Mutex<Result<Data, MapError>?>(nil)
                defer { staging.destroy() }
                let info = WebGPU.GPUBufferMapCallbackInfo(
                    mode: .allowProcessEvents,
                    callback: { [length] status, message in
                        let mapped: Result<Data, MapError>
                        if status != .success {
                            mapped = .failure(.failedToMap(message ?? "GPU mapping failed"))
                        } else if let pointer = unsafe staging.getConstMappedRange(offset: 0, size: length) {
                            mapped = .success(unsafe Data(bytes: pointer, count: length))
                            staging.unmap()
                        } else {
                            mapped = .failure(.failedToGetMappedRange)
                            staging.unmap()
                        }
                        result.withLock { $0 = mapped }
                    }
                )
                info.withWGPUStruct { native in
                    native.callback = { status, message, userdata, _ in
                        guard let userdata else { return }
                        let callback = Unmanaged<AnyObject>.fromOpaque(userdata).takeRetainedValue() as! WebGPU.GPUBufferMapCallback
                        callback(status, message.toString)
                    }
                    _ = staging.mapAsync(mode: .read, offset: 0, size: length, callbackInfo: native)
                }
                let deadline = ContinuousClock.now + .seconds(30)
                while true {
                    try Task.checkCancellation()
                    webGPUDeviceLock.withLock { _ in instance.processEvents() }
                    if let mapped = result.withLock({ $0 }) { return try mapped.get() }
                    guard ContinuousClock.now < deadline else { throw MapError.failedToMap("GPU mapping timed out") }
                    try await Task.sleep(for: .milliseconds(1))
                }
            }
            #endif
            return try await withCheckedThrowingContinuation { continuation in
                _ = staging.mapAsync(mode: .read, offset: 0, size: length, callbackInfo: WebGPU.GPUBufferMapCallbackInfo(
                    mode: .allowSpontaneous,
                    callback: { [length] status, message in
                        guard status == .success else {
                            staging.destroy()
                            continuation.resume(throwing: MapError.failedToMap(message ?? "GPU mapping failed"))
                            return
                        }
                        guard let pointer = unsafe staging.getConstMappedRange(offset: 0, size: length) else {
                            staging.unmap()
                            staging.destroy()
                            continuation.resume(throwing: MapError.failedToGetMappedRange)
                            return
                        }
                        let data = unsafe Data(bytes: pointer, count: length)
                        staging.unmap()
                        staging.destroy()
                        continuation.resume(returning: data)
                    }
                ))
            }
        }

        enum MapError: Error {
            case failedToGetMappedRange
            case failedToMap(String)
        }
    }

    extension BufferMapMode {
        var toWebGPU: WebGPU.GPUMapMode {
            switch self {
            case .read:
                return .read
            case .write:
                return .write
            default:
                return []
            }
        }
    }

#endif
