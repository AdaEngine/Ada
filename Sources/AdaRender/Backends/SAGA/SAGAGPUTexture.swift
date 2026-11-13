//
//  SAGAGPUTexture.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import Foundation
    import Math
    import SAGA
    import SAGACore
    import SAGATypes

    enum SAGATextureError: Error {
        case unsupportedPixelFormat
        case readbackUnavailable
    }

    extension PixelFormat {
        /// Browser mapping; depth/stencil uses the 24-bit variant WebGPU guarantees.
        var sagaFormat: TextureFormat? {
            switch self {
            case .none: nil
            case .bgra8: .bgra8Unorm
            case .bgra8_srgb: .bgra8UnormSrgb
            case .rgba8: .rgba8Unorm
            case .rgba_16f: .rgba16Float
            case .rgba_32f: .rgba32Float
            case .r32f: .r32Float
            case .depth_32f_stencil8, .depth24_stencil8: .depth24PlusStencil8
            case .depth_32f: .depth32Float
            }
        }
    }

    @_spi(Internal)
    public final class SAGAGPUTexture: GPUTexture, TextureSubresourceUploading, @unchecked Sendable {
        public let size: SizeInt
        public var label: String?
        let context: SAGAContext
        let slot: ResourceSlot<ResourceID>
        /// What sampling binds. Array and cube textures need an explicit view: a one-layer array otherwise resolves to a
        /// plain 2D view and a cube to an array view, which a `texture_2d_array` or `texture_cube` binding rejects.
        let sampledSlot: ResourceSlot<ResourceID>
        private let viewSlot: ResourceSlot<ResourceID>?
        let pixelFormat: PixelFormat
        let allowsBindingCache: Bool
        let allowsTransientBindingCache: Bool
        private let ownsResource: Bool

        init(context: SAGAContext, descriptor: TextureDescriptor) throws {
            guard let format = descriptor.pixelFormat.sagaFormat else {
                throw SAGATextureError.unsupportedPixelFormat
            }
            self.context = context
            self.size = SizeInt(width: descriptor.width, height: descriptor.height)
            self.label = descriptor.debugLabel
            self.pixelFormat = descriptor.pixelFormat
            self.allowsBindingCache = descriptor.allowsBindingCache && !descriptor.textureUsage.contains(.renderTarget)
            self.allowsTransientBindingCache = descriptor.allowsBindingCache
            self.ownsResource = true

            var usage: TextureUsage = []
            if descriptor.textureUsage.contains(.read) {
                usage.formUnion([.copyDestination, .copySource, .textureBinding])
            }
            if descriptor.textureUsage.contains(.write) {
                usage.insert(.copySource)
            }
            if descriptor.textureUsage.contains(.renderTarget) {
                usage.formUnion([.renderAttachment, .copySource])
            } else {
                usage.insert(.textureBinding)
            }
            // Uploads need a copy destination even for textures declared write-only.
            usage.insert(.copyDestination)

            let layers: Int = descriptor.textureType == .textureCube
                ? 6 : (descriptor.textureType == .texture2DArray ? max(1, descriptor.arrayLength) : 1)
            let sagaDescriptor = SAGATypes.TextureDescriptor(
                width: UInt32(descriptor.width),
                height: UInt32(descriptor.height),
                format: format,
                usage: usage,
                mipLevelCount: UInt32(max(1, descriptor.mipmapLevel)),
                arrayLayerCount: UInt32(layers),
                dimension: descriptor.textureType == .texture3D ? .d3 : (descriptor.textureType == .texture1D ? .d1 : .d2)
            )
            let slot = ResourceSlot<ResourceID>()
            self.slot = slot
            context.queue.enqueue { device in
                slot.fulfill(try await device.createTexture(sagaDescriptor))
            }
            let viewDimension: TextureViewDimension? = switch descriptor.textureType {
            case .texture2DArray: .d2Array
            case .textureCube: .cube
            default: nil
            }
            if let viewDimension {
                let view = ResourceSlot<ResourceID>()
                self.viewSlot = view
                self.sampledSlot = view
                context.queue.enqueue { device in
                    view.fulfill(try await device.createTextureView(texture: try slot.get(), .init(dimension: viewDimension)))
                }
            } else {
                self.viewSlot = nil
                self.sampledSlot = slot
            }

            let initial = descriptor.image.map { [TextureSubresource(image: $0, mipLevel: 0)] } ?? []
            for subresource in initial + descriptor.subresources {
                try? uploadSubresource(subresource)
            }
        }

        deinit {
            guard ownsResource else { return }
            let slot = self.slot
            let viewSlot = self.viewSlot
            context.queue.enqueue { device in
                if let viewSlot, let view = try? viewSlot.get() {
                    try await device.destroyTextureView(view)
                }
                if let id = try? slot.get() {
                    try await device.destroyTexture(id)
                }
            }
        }

        public func replaceRegion(_ region: RectInt, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {
            let data = unsafe [UInt8](UnsafeRawBufferPointer(start: bytes, count: bytesPerRow * region.size.height))
            write(
                data,
                bytesPerRow: bytesPerRow,
                region: TextureCopyRegion(
                    x: UInt32(region.origin.x), y: UInt32(region.origin.y),
                    width: UInt32(region.size.width), height: UInt32(region.size.height),
                    mipLevel: UInt32(mipmapLevel)
                )
            )
        }

        func uploadSubresource(_ resource: TextureSubresource) throws {
            let image = resource.image
            let bytesPerRow = pixelFormat.bytesPerComponent * image.width
            let data = unsafe image.data.withUnsafeBytes { unsafe [UInt8]($0) }
            write(
                data,
                bytesPerRow: bytesPerRow,
                region: TextureCopyRegion(
                    width: UInt32(image.width), height: UInt32(image.height),
                    mipLevel: UInt32(resource.mipLevel), arrayLayer: UInt32(resource.slice)
                )
            )
        }

        private func write(_ data: [UInt8], bytesPerRow: Int, region: TextureCopyRegion) {
            let slot = self.slot
            let layout = TextureDataLayout(bytesPerRow: UInt32(bytesPerRow), rowsPerImage: region.height)
            context.queue.enqueue { device in
                _ = try await device.writeTexture(try slot.get(), data: data, layout: layout, region: region)
            }
        }

        /// Reads mip 0 through an aligned staging buffer. Only 8-bit color formats convert to ``Image``.
        func readImage() async throws -> Image? {
            let imageFormat: Image.Format
            switch pixelFormat {
            case .bgra8: imageFormat = .bgra8
            case .bgra8_srgb: imageFormat = .bgra8_sRGB
            case .rgba8: imageFormat = .rgba8
            default: return nil
            }
            let width = size.width
            let height = size.height
            let bytesPerRow = width * 4
            let padded = (bytesPerRow + 255) & ~255
            let staging = context.createBuffer(
                BufferDescriptor(label: "texture-readback", size: UInt64(padded * height), usage: [.copyDestination, .mapRead])
            )
            let source = self.slot
            let bytes: [UInt8] = try await withCheckedThrowingContinuation { continuation in
                context.queue.enqueue { device in
                    do {
                        let src = try source.get()
                        let dst = try staging.get()
                        _ = try await device.submitCommands([
                            .copyTextureToBuffer(source: src, destination: dst, bytesPerRow: UInt32(padded))
                        ]).wait()
                        let mapping = try await device.mapBuffer(dst, mode: .read)
                        let data = try await device.readMappedBytes(mapping)
                        try await device.unmapBuffer(dst)
                        try await device.destroyBuffer(dst)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            var pixels = Data(capacity: bytesPerRow * height)
            for row in 0..<height {
                let offset = row * padded
                pixels.append(contentsOf: bytes[offset..<(offset + bytesPerRow)])
            }
            return Image(width: width, height: height, data: pixels, format: imageFormat)
        }
    }
#endif
