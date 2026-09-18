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
        public var size: SizeInt {
            SizeInt(width: Int(self.texture.width), height: Int(self.texture.height))
        }

        public var label: String? {
            didSet {
                self.texture.setLabel(label: label ?? "")
                self.textureView.setLabel(label: label ?? "")
            }
        }

        public let texture: WebGPU.GPUTexture
        public let textureView: WebGPU.GPUTextureView
        private let device: WebGPU.GPUDevice?

        init(texture: WebGPU.GPUTexture, textureView: WebGPU.GPUTextureView, device: WebGPU.GPUDevice? = nil) {
            self.texture = texture
            self.textureView = textureView
            self.device = device
        }

        public func replaceRegion(_ region: RectInt, mipmapLevel: Int, withBytes bytes: UnsafeRawPointer, bytesPerRow: Int) {
            guard let device else {
                fatalError("Cannot replace a region on a WebGPU texture without a device")
            }

            webGPUDeviceLock.withLock { _ in
                device.queue.writeTexture(
                    destination: WebGPU.GPUTexelCopyTextureInfo(
                        texture: texture,
                        mipLevel: UInt32(mipmapLevel),
                        origin: WebGPU.GPUOrigin3D(
                            x: region.origin.x,
                            y: region.origin.y,
                            z: 0
                        ),
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
                        depthOrArrayLayers: 1
                    ),
                    format: descriptor.pixelFormat.toWebGPU,
                    mipLevelCount: 1,
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
                        depthOrArrayLayers: 1
                    ),
                    format: descriptor.pixelFormat.toWebGPU,
                    mipLevelCount: 1,
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
            if let image = descriptor.image {
                let origin = WebGPU.GPUOrigin3D(x: 0, y: 0, z: 0)
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
                                mipLevel: 0,
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
            self.textureView = texture.createView()
            self.device = device
        }

        // TODO: (Vlad) think about it later
        func getImage(device: WebGPU.GPUDevice) -> Image? {
            #if WASM
                return nil
            #else
                let imageFormat: Image.Format
                let bytesInPixel: UInt32

                switch self.texture.format {
                case .BGRA8Unorm:
                    imageFormat = .bgra8
                    bytesInPixel = 4
                default:
                    imageFormat = .rgba8
                    bytesInPixel = 4
                }

                let bytesPerRow = self.texture.width * bytesInPixel
                let pixelCount = UInt32(self.texture.width * self.texture.height)
                let count = Int(pixelCount * bytesInPixel)
                nonisolated(unsafe) var readbackBuffer: WebGPU.GPUBuffer?
                webGPUDeviceLock.withLock { _ in
                    readbackBuffer = device.createBuffer(descriptor: WebGPU.GPUBufferDescriptor(usage: .copyDst, size: UInt64(count)))
                }
                guard let buffer = readbackBuffer else {
                    return nil
                }
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
                        layout: WebGPU.GPUTexelCopyBufferLayout(offset: UInt64(0), bytesPerRow: UInt32(bytesPerRow), rowsPerImage: texture.height),
                        buffer: buffer
                    ),
                    copySize: WebGPU.GPUExtent3D(
                        width: texture.width,
                        height: texture.height,
                        depthOrArrayLayers: 1
                    )
                )
                let commandBuffer: WebGPU.GPUCommandBuffer = encoder.finish(descriptor: nil as WebGPU.GPUCommandBufferDescriptor?)
                webGPUDeviceLock.withLock { _ in
                    device.queue.submit(commands: [commandBuffer])
                }

                return unsafe Image(
                    width: Int(self.texture.width),
                    height: Int(self.texture.height),
                    data: Data(
                        bytesNoCopy: buffer.getMappedRange(offset: 0, size: count),
                        count: count,
                        deallocator: .custom { [buffer] _, _ in
                            buffer.unmap()
                        }
                    ),
                    format: imageFormat
                )
            #endif
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
    }

#endif
