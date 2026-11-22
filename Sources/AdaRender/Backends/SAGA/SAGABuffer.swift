//
//  SAGABuffer.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import Foundation
    import SAGA
    import SAGACore
    import SAGAShaderIR
    import SAGATypes
    import Synchronization

    extension ResourceOptions {
        /// Every AdaRender buffer may be written by the CPU and read by any pipeline stage.
        var sagaUsage: BufferUsage {
            [.copySource, .copyDestination, .storage, .uniform, .vertex, .index, .indirect]
        }
    }

    /// A GPU buffer backed by a SAGA resource.
    ///
    /// The buffer keeps a CPU shadow so ``contents()`` can hand out a writable pointer that is uploaded by ``unmap()``.
    @_spi(Internal)
    public class SAGABuffer: Buffer, @unchecked Sendable {
        private struct Upload: Sendable {
            let slot: ResourceSlot<ResourceID>
            let offset: UInt64
            let bytes: [UInt8]
        }

        let context: SAGAContext
        let slot: ResourceSlot<ResourceID>
        let usage: BufferUsage
        public let length: Int
        public var label: String?
        @unsafe private let shadow: UnsafeMutableRawPointer
        private let tracksShadowInput: Bool
        private let shadowGeneration = Mutex<UInt64?>(0)

        init(context: SAGAContext, label: String?, length: Int, usage: BufferUsage, tracksShadowInput: Bool = false) {
            self.context = context
            self.usage = usage
            self.label = label
            self.length = length
            self.tracksShadowInput = tracksShadowInput
            unsafe self.shadow = UnsafeMutableRawPointer.allocate(byteCount: max(length, 1), alignment: 16)
            unsafe self.shadow.initializeMemory(as: UInt8.self, repeating: 0, count: max(length, 1))
            self.slot = context.createBuffer(
                BufferDescriptor(label: label ?? "", size: UInt64(length), usage: usage)
            )
        }

        var shadowRasterRevision: UInt64? {
            tracksShadowInput ? shadowGeneration.withLock { $0 } : nil
        }

        var hasUntrackedShadowWrites: Bool {
            tracksShadowInput && shadowGeneration.withLock { $0 == nil }
        }

        func markShadowInputChanged() {
            if tracksShadowInput {
                shadowGeneration.withLock { generation in generation = generation.map { $0 &+ 1 } }
            }
        }

        func excludeFromShadowCache() {
            // A write encoded for later submission need not be covered by a future CPU upload.
            if tracksShadowInput { shadowGeneration.withLock { $0 = nil } }
        }

        deinit {
            unsafe shadow.deallocate()
            let slot = self.slot
            context.queue.enqueue { device in
                if let id = try? slot.get() {
                    try await device.destroyBuffer(id)
                }
            }
        }

        public func contents() -> UnsafeMutableRawPointer {
            unsafe shadow
        }

        public func unmap() {
            upload(offset: 0, byteCount: length)
        }

        public func setData(_ bytes: UnsafeMutableRawPointer, byteCount: Int, offset: Int) {
            guard byteCount > 0, offset >= 0, offset + byteCount <= length else { return }
            unsafe (shadow + offset).copyMemory(from: bytes, byteCount: byteCount)
            upload(offset: offset, byteCount: byteCount)
        }

        public func readData() async throws -> Data {
            let source = self.slot
            let length = self.length
            let staging = context.createBuffer(
                BufferDescriptor(label: "readback", size: UInt64((length + 3) & ~3), usage: [.copyDestination, .mapRead])
            )
            return try await withCheckedThrowingContinuation { continuation in
                context.queue.enqueue { device in
                    do {
                        let src = try source.get()
                        let dst = try staging.get()
                        _ = try await device.submitCommands([.copy(source: src, destination: dst)]).wait()
                        let mapping = try await device.mapBuffer(dst, mode: .read)
                        let bytes = try await device.readMappedBytes(mapping)
                        try await device.unmapBuffer(dst)
                        try await device.destroyBuffer(dst)
                        continuation.resume(returning: Data(bytes.prefix(length)))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        private func upload(offset: Int, byteCount: Int) {
            markShadowInputChanged()
            let bytes = unsafe [UInt8](UnsafeRawBufferPointer(start: shadow + offset, count: byteCount))
            let slot = self.slot
            if context.shaderOutput == .msl {
                context.queue.enqueueAdjacent(Upload(slot: slot, offset: UInt64(offset), bytes: bytes)) { device, uploads in
                    do {
                        let commands = try uploads.map {
                            try BufferCommand.writeBytes(buffer: $0.slot.get(), offset: $0.offset, bytes: $0.bytes)
                        }
                        _ = try await device.submitCommands(commands)
                    } catch {
                        // Preserve the valid neighbors if one upload was rejected before submission.
                        var firstFailure: (any Error)?
                        for upload in uploads {
                            do {
                                _ = try await device.writeBuffer(try upload.slot.get(), offset: upload.offset, bytes: upload.bytes)
                            } catch {
                                if firstFailure == nil { firstFailure = error }
                            }
                        }
                        if let firstFailure { throw firstFailure }
                    }
                }
            } else {
                context.queue.enqueue { device in
                    _ = try await device.writeBuffer(try slot.get(), offset: UInt64(offset), bytes: bytes)
                }
            }
        }
    }

    @_spi(Internal)
    public final class SAGAUniformBuffer: SAGABuffer, UniformBuffer, @unchecked Sendable {
        public let binding: Int

        init(context: SAGAContext, length: Int, binding: Int) {
            self.binding = binding
            // WebGPU requires uniform buffers aligned to 16 bytes.
            super.init(context: context, label: nil, length: (length + 15) & ~15, usage: ResourceOptions.storageShared.sagaUsage)
        }
    }

    @_spi(Internal)
    public final class SAGAVertexBuffer: SAGABuffer, VertexBuffer, @unchecked Sendable {
        public let binding: Int

        init(context: SAGAContext, label: String?, length: Int, binding: Int) {
            self.binding = binding
            super.init(context: context, label: label, length: length, usage: ResourceOptions.storageShared.sagaUsage, tracksShadowInput: true)
        }
    }

    @_spi(Internal)
    public final class SAGAIndexBuffer: SAGABuffer, IndexBuffer, @unchecked Sendable {
        public let indexFormat: IndexBufferFormat

        init(context: SAGAContext, label: String?, format: IndexBufferFormat, length: Int) {
            self.indexFormat = format
            super.init(context: context, label: label, length: (length + 3) & ~3, usage: ResourceOptions.storageShared.sagaUsage, tracksShadowInput: true)
        }
    }
#endif
