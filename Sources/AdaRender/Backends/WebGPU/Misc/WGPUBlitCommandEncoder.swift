//
//  MetalBlitCommandEncoder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    import Foundation
    @unsafe @preconcurrency import WebGPU

    final class WGPUBlitCommandEncoder: BlitCommandEncoder {
        let blitEncoder: WebGPU.GPUCommandEncoder
        let device: WebGPU.GPUDevice

        init(
            blitEncoder: WebGPU.GPUCommandEncoder,
            device: WebGPU.GPUDevice
        ) {
            self.blitEncoder = blitEncoder
            self.device = device
        }

        func pushDebugName(_ string: String) {
            #if !WASM
                blitEncoder.pushDebugGroup(groupLabel: string)
            #endif
        }

        func popDebugName() {
            #if !WASM
                blitEncoder.popDebugGroup()
            #endif
        }

        func copyTextureToTexture(
            source: Texture,
            sourceOrigin: Origin3D,
            sourceSize: Size3D,
            sourceMipLevel: Int,
            sourceSlice _: Int,
            destination: Texture,
            destinationOrigin: Origin3D,
            destinationMipLevel: Int,
            destinationSlice _: Int
        ) {
            guard
                let src = source.gpuTexture as? WGPUGPUTexture,
                let dst = destination.gpuTexture as? WGPUGPUTexture
            else {
                fatalError("Textures must be WGPU textures")
            }

            #if WASM
                fatalError("copyTextureToTexture is not implemented by Swan's WASM WebGPU bridge.")
            #else
                blitEncoder.copyTextureToTexture(
                    source: WebGPU.GPUTexelCopyTextureInfo(
                        texture: src.texture,
                        mipLevel: UInt32(sourceMipLevel),
                        origin: WebGPU.GPUOrigin3D(x: sourceOrigin.x, y: sourceOrigin.y, z: sourceOrigin.z),
                        aspect: WebGPU.GPUTextureAspect.all
                    ),
                    destination: WebGPU.GPUTexelCopyTextureInfo(
                        texture: dst.texture,
                        mipLevel: UInt32(destinationMipLevel),
                        origin: WebGPU.GPUOrigin3D(x: destinationOrigin.x, y: destinationOrigin.y, z: destinationOrigin.z),
                        aspect: WebGPU.GPUTextureAspect.all
                    ),
                    copySize: WebGPU.GPUExtent3D(
                        width: UInt32(sourceSize.width),
                        height: UInt32(sourceSize.height),
                        depthOrArrayLayers: 1
                    )
                )
            #endif
        }

        func copyBufferToBuffer(
            source: Buffer,
            sourceOffset: Int,
            destination: Buffer,
            destinationOffset: Int,
            size: Int
        ) {
            guard
                let src = source as? WGPUBuffer,
                let dst = destination as? WGPUBuffer
            else {
                fatalError("Buffers must be WGPU buffers")
            }
            blitEncoder.copyBufferToBuffer(
                source: src.buffer,
                sourceOffset: UInt64(sourceOffset),
                destination: dst.buffer,
                destinationOffset: UInt64(destinationOffset),
                size: UInt64(size)
            )
        }

        func copyBufferToTexture(
            source: Buffer,
            sourceOffset: Int,
            sourceBytesPerRow: Int,
            sourceBytesPerImage: Int,
            sourceSize: Size3D,
            destination: Texture,
            destinationOrigin: Origin3D,
            destinationMipLevel: Int,
            destinationSlice _: Int
        ) {
            guard
                let src = source as? WGPUBuffer,
                let dst = destination.gpuTexture as? WGPUGPUTexture
            else {
                fatalError("Invalid WGPU resources")
            }

            blitEncoder.copyBufferToTexture(
                source: WebGPU.GPUTexelCopyBufferInfo(
                    layout: WebGPU.GPUTexelCopyBufferLayout(
                        offset: UInt64(sourceOffset),
                        bytesPerRow: UInt32(sourceBytesPerRow),
                        rowsPerImage: UInt32(sourceBytesPerImage)
                    ),
                    buffer: src.buffer
                ),
                destination: WebGPU.GPUTexelCopyTextureInfo(
                    texture: dst.texture,
                    mipLevel: UInt32(destinationMipLevel),
                    origin: WebGPU.GPUOrigin3D(x: destinationOrigin.x, y: destinationOrigin.y, z: destinationOrigin.z),
                    aspect: WebGPU.GPUTextureAspect.all
                ),
                copySize: WebGPU.GPUExtent3D(
                    width: UInt32(sourceSize.width),
                    height: UInt32(sourceSize.height),
                    depthOrArrayLayers: 1
                )
            )
        }

        func copyTextureToBuffer(
            source: Texture,
            sourceOrigin: Origin3D,
            sourceMipLevel: Int,
            sourceSlice _: Int,
            sourceSize: Size3D,
            destination: Buffer,
            destinationOffset: Int,
            destinationBytesPerRow: Int,
            destinationBytesPerImage: Int
        ) {
            guard
                let src = source.gpuTexture as? WGPUGPUTexture,
                let dst = destination as? WGPUBuffer
            else {
                fatalError("Invalid WGPU resources")
            }

            blitEncoder.copyTextureToBuffer(
                source: WebGPU.GPUTexelCopyTextureInfo(
                    texture: src.texture,
                    mipLevel: UInt32(sourceMipLevel),
                    origin: WebGPU.GPUOrigin3D(x: sourceOrigin.x, y: sourceOrigin.y, z: sourceOrigin.z),
                    aspect: WebGPU.GPUTextureAspect.all
                ),
                destination: WebGPU.GPUTexelCopyBufferInfo(
                    layout: WebGPU.GPUTexelCopyBufferLayout(
                        offset: UInt64(destinationOffset),
                        bytesPerRow: UInt32(destinationBytesPerRow),
                        rowsPerImage: UInt32(destinationBytesPerImage)
                    ),
                    buffer: dst.buffer
                ),
                copySize: WebGPU.GPUExtent3D(
                    width: UInt32(sourceSize.width),
                    height: UInt32(sourceSize.height),
                    depthOrArrayLayers: 1
                )
            )
        }

        func endBlitPass() {}
    }
#endif
