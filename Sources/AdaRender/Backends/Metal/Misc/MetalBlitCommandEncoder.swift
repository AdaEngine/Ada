//
//  MetalBlitCommandEncoder.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if canImport(Metal)
    import Foundation
    import Metal

    final class MetalBlitCommandEncoder: BlitCommandEncoder {
        let blitEncoder: MTLBlitCommandEncoder

        init(blitEncoder: MTLBlitCommandEncoder) {
            self.blitEncoder = blitEncoder
        }

        func pushDebugName(_ string: String) {
            blitEncoder.pushDebugGroup(string)
        }

        func popDebugName() {
            blitEncoder.popDebugGroup()
        }

        func copyTextureToTexture(
            source: Texture,
            sourceOrigin: Origin3D,
            sourceSize: Size3D,
            sourceMipLevel: Int,
            sourceSlice: Int,
            destination: Texture,
            destinationOrigin: Origin3D,
            destinationMipLevel: Int,
            destinationSlice: Int
        ) {
            guard
                let src = source.gpuTexture as? MetalGPUTexture,
                let dst = destination.gpuTexture as? MetalGPUTexture
            else {
                fatalError("Textures must be Metal textures")
            }

            blitEncoder.copy(
                from: src.texture,
                sourceSlice: sourceSlice,
                sourceLevel: sourceMipLevel,
                sourceOrigin: MTLOrigin(x: sourceOrigin.x, y: sourceOrigin.y, z: sourceOrigin.z),
                sourceSize: MTLSize(width: sourceSize.width, height: sourceSize.height, depth: sourceSize.depth),
                to: dst.texture,
                destinationSlice: destinationSlice,
                destinationLevel: destinationMipLevel,
                destinationOrigin: MTLOrigin(x: destinationOrigin.x, y: destinationOrigin.y, z: destinationOrigin.z)
            )
        }

        func copyBufferToBuffer(
            source: Buffer,
            sourceOffset: Int,
            destination: Buffer,
            destinationOffset: Int,
            size: Int
        ) {
            guard
                let src = source as? MetalBuffer,
                let dst = destination as? MetalBuffer
            else {
                fatalError("Buffers must be Metal buffers")
            }

            blitEncoder.copy(
                from: src.buffer,
                sourceOffset: sourceOffset,
                to: dst.buffer,
                destinationOffset: destinationOffset,
                size: size
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
            destinationSlice: Int
        ) {
            guard
                let src = source as? MetalBuffer,
                let dst = destination.gpuTexture as? MetalGPUTexture
            else {
                fatalError("Invalid Metal resources")
            }

            blitEncoder.copy(
                from: src.buffer,
                sourceOffset: sourceOffset,
                sourceBytesPerRow: sourceBytesPerRow,
                sourceBytesPerImage: sourceBytesPerImage,
                sourceSize: MTLSize(width: sourceSize.width, height: sourceSize.height, depth: sourceSize.depth),
                to: dst.texture,
                destinationSlice: destinationSlice,
                destinationLevel: destinationMipLevel,
                destinationOrigin: MTLOrigin(x: destinationOrigin.x, y: destinationOrigin.y, z: destinationOrigin.z)
            )
        }

        func copyTextureToBuffer(
            source: Texture,
            sourceOrigin: Origin3D,
            sourceMipLevel: Int,
            sourceSlice: Int,
            sourceSize: Size3D,
            destination: Buffer,
            destinationOffset: Int,
            destinationBytesPerRow: Int,
            destinationBytesPerImage: Int
        ) {
            guard
                let src = source.gpuTexture as? MetalGPUTexture,
                let dst = destination as? MetalBuffer
            else {
                fatalError("Invalid Metal resources")
            }

            blitEncoder.copy(
                from: src.texture,
                sourceSlice: sourceSlice,
                sourceLevel: sourceMipLevel,
                sourceOrigin: MTLOrigin(x: sourceOrigin.x, y: sourceOrigin.y, z: sourceOrigin.z),
                sourceSize: MTLSize(width: sourceSize.width, height: sourceSize.height, depth: sourceSize.depth),
                to: dst.buffer,
                destinationOffset: destinationOffset,
                destinationBytesPerRow: destinationBytesPerRow,
                destinationBytesPerImage: destinationBytesPerImage
            )
        }

        func endBlitPass() {
            blitEncoder.endEncoding()
        }
    }
#endif
