//
//  WGPUGPUTexture.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 13.03.2025.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import Foundation
    import Math
    import Synchronization
    @unsafe @preconcurrency import WebGPU

    public final class WGPUGPUTexture: GPUTexture {
        public let size: SizeInt

        public var label: String? {
            didSet {
                self.texture.setLabel(label: label ?? "")
                self.textureView.setLabel(label: label ?? "")
            }
        }

        public let texture: WebGPU.GPUTexture
        public let textureView: WebGPU.GPUTextureView
        private let device: WebGPU.GPUDevice?
        private let allowsReadback: Bool
        // Render attachments can be replaced every frame. A long-lived bind-group
        // cache must not keep their full GPU allocations alive through its owners.
        let allowsBindingCache: Bool

        init(texture: WebGPU.GPUTexture, textureView: WebGPU.GPUTextureView, device: WebGPU.GPUDevice? = nil) {
            self.texture = texture
            self.size = SizeInt(width: Int(texture.width), height: Int(texture.height))
            self.textureView = textureView
            self.device = device
            self.allowsBindingCache = false
            #if WASM
            self.allowsReadback = false
            #else
            self.allowsReadback = texture.usage.contains(.copySrc)
            #endif
        }

        public func replaceRegion(_ region: RectInt, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {
            guard let device else {
                fatalError("Cannot replace a region on a WebGPU texture without a device")
            }

            #if WASM
            let origin = WebGPU.GPUOrigin3D(x: region.origin.x, y: region.origin.y, z: 0)
            #else
            let origin = WebGPU.GPUOrigin3D(x: UInt32(region.origin.x), y: UInt32(region.origin.y), z: 0)
            #endif
            webGPUDeviceLock.withLock { _ in
                device.queue.writeTexture(
                    destination: WebGPU.GPUTexelCopyTextureInfo(
                        texture: texture,
                        mipLevel: UInt32(mipmapLevel),
                        origin: origin,
                        aspect: WebGPU.GPUTextureAspect.all
                    ),
                    data: UnsafeRawBufferPointer(
                        start: bytes,
                        count: bytesPerRow * region.size.height
                    ),
                    dataLayout: WebGPU.GPUTexelCopyBufferLayout(
                        offset: 0,
                        bytesPerRow: UInt32(bytesPerRow),
                        rowsPerImage: UInt32(region.size.height)
                    ),
                    writeSize: WebGPU.GPUExtent3D(
                        width: UInt32(region.size.width),
                        height: UInt32(region.size.height),
                        depthOrArrayLayers: 1
                    )
                )
            }
        }

        init(descriptor: TextureDescriptor, device: WebGPU.GPUDevice) {
            self.allowsBindingCache = !descriptor.textureUsage.contains(.renderTarget)
            self.size = SizeInt(width: descriptor.width, height: descriptor.height)
            var wgpuUsage: WebGPU.GPUTextureUsage = []

            if descriptor.textureUsage.contains(.read) {
                wgpuUsage.insert(.copyDst)
                wgpuUsage.insert(.textureBinding)
            }

            if descriptor.textureUsage.contains(.write) {
                wgpuUsage.insert(.copySrc)
            }

            if descriptor.textureUsage.contains(.renderTarget) {
                wgpuUsage.insert(.renderAttachment)
                wgpuUsage.insert(.copySrc)
            }

            // Always add textureBinding for textures that will be sampled in shaders
            if !descriptor.textureUsage.contains(.renderTarget) {
                wgpuUsage.insert(.textureBinding)
            }

            #if WASM
                let textureDesc = WebGPU.GPUTextureDescriptor(
                    label: descriptor.debugLabel,
                    usage: wgpuUsage,
                    size: WebGPU.GPUExtent3D(
                        width: UInt32(descriptor.width),
                        height: UInt32(descriptor.height),
                        depthOrArrayLayers: descriptor.textureType == .textureCube ? 6 : 1
                    ),
                    format: descriptor.pixelFormat.toWebGPU,
                    mipLevelCount: UInt32(max(1, descriptor.mipmapLevel)),
                    sampleCount: 1,
                    dimension: descriptor.textureType.toWebGPUTextureDimension
                )
            #else
                let textureDesc = WebGPU.GPUTextureDescriptor(
                    label: descriptor.debugLabel,
                    usage: wgpuUsage,
                    dimension: descriptor.textureType.toWebGPUTextureDimension,
                    size: WebGPU.GPUExtent3D(
                        width: UInt32(descriptor.width),
                        height: UInt32(descriptor.height),
                        depthOrArrayLayers: descriptor.textureType == .textureCube ? 6 : 1
                    ),
                    format: descriptor.pixelFormat.toWebGPU,
                    mipLevelCount: UInt32(max(1, descriptor.mipmapLevel)),
                    sampleCount: 1,
                    viewFormats: [
                        descriptor.pixelFormat.toWebGPU
                    ],
                    nextInChain: nil
                )
            #endif

            let texture = webGPUDeviceLock.withLock { _ in
                device.createTexture(descriptor: textureDesc)
            }
            let initialImages = descriptor.image.map { [TextureSubresource(image: $0, mipLevel: 0)] } ?? []
            for subresource in initialImages + descriptor.subresources {
                let image = subresource.image
                #if WASM
                let origin = WebGPU.GPUOrigin3D(x: 0, y: 0, z: subresource.slice)
                #else
                let origin = WebGPU.GPUOrigin3D(x: 0, y: 0, z: UInt32(subresource.slice))
                #endif
                let writeSize = WebGPU.GPUExtent3D(
                    width: UInt32(image.width),
                    height: UInt32(image.height),
                    depthOrArrayLayers: 1
                )

                let bytesPerRow = descriptor.pixelFormat.bytesPerComponent * image.width

                unsafe image.data.withUnsafeBytes { buffer in
                    unsafe precondition(buffer.baseAddress != nil, "Image should not contains empty address.")

                    webGPUDeviceLock.withLock { _ in
                        unsafe device.queue.writeTexture(
                            destination: WebGPU.GPUTexelCopyTextureInfo(
                                texture: texture,
                                mipLevel: UInt32(subresource.mipLevel),
                                origin: origin,
                                aspect: WebGPU.GPUTextureAspect.all
                            ),
                            data: buffer,
                            dataLayout: WebGPU.GPUTexelCopyBufferLayout(
                                offset: 0,
                                bytesPerRow: UInt32(bytesPerRow),
                                rowsPerImage: UInt32(image.height)
                            ),
                            writeSize: writeSize
                        )
                    }
                }
            }

            self.texture = texture
            if descriptor.textureType == .textureCube {
                self.textureView = texture.createView(descriptor: WebGPU.GPUTextureViewDescriptor(dimension: .cube))
            } else {
                self.textureView = texture.createView()
            }
            self.device = device
            self.allowsReadback = wgpuUsage.contains(.copySrc)
        }

        /// Uses aligned texture-copy rows and the existing asynchronous owned buffer readback path.
        func readImage(device: WebGPU.GPUDevice, instance: WebGPU.GPUInstance) async throws -> Image? {
                guard allowsReadback else {
                    return nil
                }
                let imageFormat: Image.Format

                switch self.texture.format {
                case .BGRA8Unorm:
                    imageFormat = .bgra8
                case .BGRA8UnormSrgb:
                    imageFormat = .bgra8_sRGB
                case .RGBA8Unorm, .RGBA8UnormSrgb:
                    imageFormat = .rgba8
                default:
                    return nil
                }

                let bytesPerRow = Int(self.texture.width) * 4
                let paddedBytesPerRow = (bytesPerRow + 255) & ~255
                let count = paddedBytesPerRow * Int(self.texture.height)
                let readback: WGPUBuffer? = webGPUDeviceLock.withLock { _ in
                    let created: WebGPU.GPUBuffer? = device.createBuffer(descriptor: WebGPU.GPUBufferDescriptor(usage: [.copyDst, .copySrc], size: UInt64(count)))
                    guard let buffer = created else {
                        return nil
                    }
                    // The existing Sendable wrapper owns the handle; device operations remain serialized by the GPU lock.
                    return WGPUBuffer(buffer: buffer, device: device, instance: instance)
                }
                guard let readback else {
                    throw WGPUBuffer.MapError.failedToMap("Cannot allocate texture readback buffer")
                }
                let buffer = readback.buffer
                defer { buffer.destroy() }
                let encoder = webGPUDeviceLock.withLock { _ in
                    device.createCommandEncoder(descriptor: nil as WebGPU.GPUCommandEncoderDescriptor?)
                }
                encoder.copyTextureToBuffer(
                    source: WebGPU.GPUTexelCopyTextureInfo(
                        texture: texture,
                        mipLevel: 0,
                        origin: WebGPU.GPUOrigin3D(x: 0, y: 0, z: 0),
                        aspect: WebGPU.GPUTextureAspect.all
                    ),
                    destination: WebGPU.GPUTexelCopyBufferInfo(
                        layout: WebGPU.GPUTexelCopyBufferLayout(offset: UInt64(0), bytesPerRow: UInt32(paddedBytesPerRow), rowsPerImage: UInt32(texture.height)),
                        buffer: buffer
                    ),
                    copySize: WebGPU.GPUExtent3D(
                        width: UInt32(texture.width),
                        height: UInt32(texture.height),
                        depthOrArrayLayers: 1
                    )
                )
                let commandBuffer: WebGPU.GPUCommandBuffer = webGPUDeviceLock.withLock { _ in
                    encoder.finish(descriptor: nil as WebGPU.GPUCommandBufferDescriptor?)
                }
                webGPUDeviceLock.withLock { _ in
                    device.queue.submit(commands: [commandBuffer])
                }

                let padded = try await readback.readData()
                var pixels = Data(capacity: bytesPerRow * Int(texture.height))
                for row in 0..<Int(texture.height) {
                    let offset = row * paddedBytesPerRow
                    pixels.append(padded[offset..<(offset + bytesPerRow)])
                }
                return Image(
                    width: Int(self.texture.width),
                    height: Int(self.texture.height),
                    data: pixels,
                    format: imageFormat
                )
        }
    }

    extension PixelFormat {
        var toWebGPU: WebGPU.GPUTextureFormat {
            switch self {
            case .none:
                #if WASM
                    .Undefined
                #else
                    .undefined
                #endif
            case .bgra8:
                .BGRA8Unorm
            case .bgra8_srgb:
                .BGRA8UnormSrgb
            case .rgba8:
                .RGBA8Unorm
            case .rgba_16f:
                .RGBA16Float
            case .rgba_32f:
                .RGBA32Float
            case .r32f:
                .R32Float
            case .depth_32f_stencil8:
                #if WASM
                    .Depth24PlusStencil8
                #else
                    .depth32FloatStencil8
                #endif
            case .depth_32f:
                #if WASM
                    .Depth32Float
                #else
                    .depth32Float
                #endif
            case .depth24_stencil8:
                #if WASM
                    .Depth24PlusStencil8
                #else
                    .depth24PlusStencil8
                #endif
            }
        }
    }

    extension Texture.TextureType {
        var toWebGPUTextureDimension: WebGPU.GPUTextureDimension {
            switch self {
            case .textureCube:
                ._2D
            case .texture1D:
                ._1D
            case .texture1DArray:
                ._1D
            case .texture2D:
                ._2D
            case .texture2DArray:
                ._2D
            case .texture2DMultisample:
                ._2D
            case .texture2DMultisampleArray:
                ._2D
            case .texture3D:
                ._3D
            case .textureBuffer:
                ._2D
            }
        }

        var toWebGPUTextureViewDimension: WebGPU.GPUTextureViewDimension {
            switch self {
            case .textureCube:
                .cube
            case .texture1D:
                ._1D
            case .texture1DArray:
                ._1D
            case .texture2D:
                ._2D
            case .texture2DArray:
                ._2D
            case .texture2DMultisample:
                ._2D
            case .texture2DMultisampleArray:
                ._2D
            case .texture3D:
                ._3D
            case .textureBuffer:
                ._2D
            }
        }
    }

#endif
