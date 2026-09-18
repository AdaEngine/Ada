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

        public var label: String? {
            didSet {
                self.buffer.setLabel(label: label ?? "")
            }
        }

        init(buffer: WebGPU.GPUBuffer, device: WebGPU.GPUDevice) {
            self.buffer = buffer
            self.device = device
        }

        public var length: Int { return Int(buffer.size) }

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
