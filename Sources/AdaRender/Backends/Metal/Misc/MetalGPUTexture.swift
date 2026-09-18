//
//  MetalGPUTexture.swift
//  AdaEngine
//
//  Created by vladislav.prusakov on 13.03.2025.
//

#if METAL
    import Math
    import Metal

    final class MetalGPUTexture: GPUTexture {
        var size: SizeInt {
            SizeInt(width: self.texture.width, height: self.texture.height)
        }

        public var label: String?

        var texture: MTLTexture

        init(texture: MTLTexture) {
            self.texture = texture
        }

        init(descriptor: TextureDescriptor, device: MTLDevice) {
            let textureDesc = MTLTextureDescriptor()

            switch descriptor.textureType {
            case .textureCube:
                textureDesc.textureType = .typeCube
            case .texture1D:
                textureDesc.textureType = .type1D
            case .texture1DArray:
                textureDesc.textureType = .type1DArray
            case .texture2D:
                textureDesc.textureType = .type2D
            case .texture2DArray:
                textureDesc.textureType = .type2DArray
            case .texture2DMultisample:
                textureDesc.textureType = .type2DMultisample
            case .texture2DMultisampleArray:
                textureDesc.textureType = .type2DMultisampleArray
            case .texture3D:
                textureDesc.textureType = .type3D
            case .textureBuffer:
                textureDesc.textureType = .typeTextureBuffer
            }

            var mtlUsage: MTLTextureUsage = []

            if descriptor.textureUsage.contains(.read) {
                mtlUsage.insert(.shaderRead)
            }

            if descriptor.textureUsage.contains(.write) {
                mtlUsage.insert(.shaderWrite)
            }

            if descriptor.textureUsage.contains(.renderTarget) {
                mtlUsage.insert(.renderTarget)
            }

            textureDesc.usage = mtlUsage
            textureDesc.width = descriptor.width
            textureDesc.height = descriptor.height
            textureDesc.pixelFormat = descriptor.pixelFormat.toMetal
            if descriptor.pixelFormat.isDepthFormat {
                textureDesc.storageMode = .private
            }

            guard let texture = device.makeTexture(descriptor: textureDesc) else {
                fatalError("Cannot create texture")
            }

            texture.label = descriptor.debugLabel

            if let image = descriptor.image {
                let region = MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: image.width, height: image.height, depth: 1)
                )

                guard let texelBytes = descriptor.pixelFormat.uncompressedColorBytesPerPixel else {
                    fatalError("MetalGPUTexture: cannot upload image data to format \(descriptor.pixelFormat).")
                }
                let minimumBytesPerRow = texelBytes * image.width
                precondition(image.height > 0, "Image height must be positive.")
                precondition(image.data.count % image.height == 0, "Image buffer size must be divisible by height.")

                if image.format == .rgb8 {
                    let (rgbaData, rgbaBytesPerRow) = Self.rgbaDataExpandingRGB8(image)
                    precondition(
                        rgbaBytesPerRow >= minimumBytesPerRow,
                        "Expanded RGBA row size \(rgbaBytesPerRow) < Metal minimum \(minimumBytesPerRow)."
                    )
                    unsafe rgbaData.withUnsafeBytes { buffer in
                        guard let baseAddress = buffer.baseAddress else {
                            preconditionFailure("Expanded image data is empty.")
                        }
                        unsafe texture.replace(
                            region: region,
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: rgbaBytesPerRow
                        )
                    }
                } else {
                    let sourceBytesPerRow = image.data.count / image.height
                    precondition(
                        sourceBytesPerRow >= minimumBytesPerRow,
                        """
                        Metal replaceRegion: bytesPerRow (\(sourceBytesPerRow)) must be >= \(minimumBytesPerRow) \
                        (width \(image.width) × \(texelBytes) B for \(descriptor.pixelFormat)). \
                        Check that Image.format matches the decoded buffer (e.g. 8-bit vs 16-bit PNG).
                        """
                    )
                    unsafe image.data.withUnsafeBytes { buffer in
                        guard let baseAddress = buffer.baseAddress else {
                            preconditionFailure("Image data is empty.")
                        }
                        unsafe texture.replace(
                            region: region,
                            mipmapLevel: 0,
                            withBytes: baseAddress,
                            bytesPerRow: sourceBytesPerRow
                        )
                    }
                }
            }

            self.texture = texture
        }

        func replaceRegion(
            _ region: RectInt,
            mipmapLevel: Int,
            withBytes bytes: UnsafeRawPointer,
            bytesPerRow: Int
        ) {
            let mtlRegion = MTLRegion(
                origin: MTLOrigin(x: region.origin.x, y: region.origin.y, z: 0),
                size: MTLSize(width: region.size.width, height: region.size.height, depth: 1)
            )

            unsafe self.texture.replace(
                region: mtlRegion,
                mipmapLevel: mipmapLevel,
                withBytes: bytes,
                bytesPerRow: bytesPerRow
            )
        }

        // TODO: (Vlad) think about it later
        func getImage() -> Image? {
            if self.texture.isFramebufferOnly {
                return nil
            }

            let imageFormat: Image.Format
            let bytesInPixel: Int

            switch self.texture.pixelFormat {
            case .bgra8Unorm:
                imageFormat = .bgra8
                bytesInPixel = 4
            default:
                imageFormat = .rgba8
                bytesInPixel = 4
            }

            let bytesPerRow = self.texture.width * bytesInPixel
            let pixelCount = self.texture.width * self.texture.height

            var imageBytes = [UInt8](repeating: 0, count: pixelCount * bytesInPixel)
            unsafe self.texture.getBytes(
                &imageBytes,
                bytesPerRow: bytesPerRow,
                from: MTLRegion(
                    origin: MTLOrigin(x: 0, y: 0, z: 0),
                    size: MTLSize(width: self.texture.width, height: self.texture.height, depth: 1)
                ),
                mipmapLevel: 0
            )

            return Image(
                width: self.texture.width,
                height: self.texture.height,
                data: Data(imageBytes),
                format: imageFormat
            )
        }

        /// Packs `rgb8` rows (with possible row padding) into tight RGBA8 for Metal `replace`.
        private static func rgbaDataExpandingRGB8(_ image: Image) -> (Data, Int) {
            precondition(image.format == .rgb8)
            let width = image.width
            let height = image.height
            precondition(width > 0 && height > 0)
            let srcRowBytes = image.data.count / height
            var out = Data(count: width * height * 4)
            out.withUnsafeMutableBytes { dstRaw in
                guard let dstBase = dstRaw.bindMemory(to: UInt8.self).baseAddress else {
                    return
                }
                image.data.withUnsafeBytes { srcRaw in
                    guard let srcBase = srcRaw.bindMemory(to: UInt8.self).baseAddress else {
                        return
                    }
                    for y in 0..<height {
                        let srow = srcBase.advanced(by: y * srcRowBytes)
                        let drow = dstBase.advanced(by: y * width * 4)
                        var sx = 0
                        var dx = 0
                        for _ in 0..<width {
                            drow[dx] = srow[sx]
                            drow[dx + 1] = srow[sx + 1]
                            drow[dx + 2] = srow[sx + 2]
                            drow[dx + 3] = 255
                            sx += 3
                            dx += 4
                        }
                    }
                }
            }
            return (out, width * 4)
        }
    }

#endif
