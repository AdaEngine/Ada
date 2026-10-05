#if METAL && canImport(MetalFX) && (os(macOS) || os(iOS))
    import Math
    import Metal
    @unsafe @preconcurrency import MetalFX
    import Synchronization

    /// The lock protects encoder-time mutation. GPU work uses one ordered command queue per render world.
    final class MetalTemporalUpscaler: TemporalUpscaler {
        private let scaler: Mutex<any MTLFXTemporalScaler>
        private let needsReset = Mutex(false)

        init?(device: MTLDevice, inputSize: SizeInt, outputSize: SizeInt) {
            guard MTLFXTemporalScalerDescriptor.supportsDevice(device),
                inputSize.width > 0, inputSize.height > 0,
                outputSize.width >= inputSize.width, outputSize.height >= inputSize.height
            else {
                return nil
            }
            let descriptor = MTLFXTemporalScalerDescriptor()
            descriptor.inputWidth = inputSize.width
            descriptor.inputHeight = inputSize.height
            descriptor.outputWidth = outputSize.width
            descriptor.outputHeight = outputSize.height
            descriptor.colorTextureFormat = .rgba16Float
            descriptor.depthTextureFormat = .depth32Float
            descriptor.motionTextureFormat = .rgba16Float
            descriptor.outputTextureFormat = .rgba16Float
            descriptor.isAutoExposureEnabled = false
            // Transparent foreground must not inherit the opaque surface history.
            descriptor.isReactiveMaskTextureEnabled = true
            descriptor.reactiveMaskTextureFormat = .bgra8Unorm
            guard let created = descriptor.makeTemporalScaler(device: device) else {
                return nil
            }
            scaler = Mutex(created)
        }

        func encode(
            commandBuffer: CommandBuffer,
            color: Texture,
            depth: Texture,
            motion: Texture,
            reactive: Texture,
            output: Texture,
            jitter: Vector2,
            reset: Bool
        ) -> Bool {
            guard let command = commandBuffer as? MetalCommandEncoder,
                let color = color.gpuTexture as? MetalGPUTexture,
                let depth = depth.gpuTexture as? MetalGPUTexture,
                let motion = motion.gpuTexture as? MetalGPUTexture,
                let reactive = reactive.gpuTexture as? MetalGPUTexture,
                let output = output.gpuTexture as? MetalGPUTexture
            else {
                return false
            }
            func isCompatible(_ texture: any MTLTexture) -> Bool {
                texture.storageMode == .private && texture.textureType == .type2D
                    && texture.device.registryID == command.commandBuffer.device.registryID
            }
            return scaler.withLock { scaler in
                guard color.texture.width == scaler.inputWidth, color.texture.height == scaler.inputHeight,
                    depth.texture.width == scaler.inputWidth, depth.texture.height == scaler.inputHeight,
                    motion.texture.width == scaler.inputWidth, motion.texture.height == scaler.inputHeight,
                    reactive.texture.width == scaler.inputWidth, reactive.texture.height == scaler.inputHeight,
                    output.texture.width == scaler.outputWidth, output.texture.height == scaler.outputHeight,
                    isCompatible(color.texture), isCompatible(depth.texture), isCompatible(motion.texture),
                    isCompatible(reactive.texture), isCompatible(output.texture),
                    color.texture.pixelFormat == scaler.colorTextureFormat,
                    depth.texture.pixelFormat == scaler.depthTextureFormat,
                    motion.texture.pixelFormat == scaler.motionTextureFormat,
                    reactive.texture.pixelFormat == scaler.reactiveMaskTextureFormat,
                    output.texture.pixelFormat == scaler.outputTextureFormat,
                    color.texture.usage.isSuperset(of: scaler.colorTextureUsage),
                    depth.texture.usage.isSuperset(of: scaler.depthTextureUsage),
                    motion.texture.usage.isSuperset(of: scaler.motionTextureUsage),
                    reactive.texture.usage.isSuperset(of: scaler.reactiveTextureUsage),
                    output.texture.usage.isSuperset(of: scaler.outputTextureUsage)
                else {
                    return false
                }
                scaler.colorTexture = color.texture
                scaler.depthTexture = depth.texture
                scaler.motionTexture = motion.texture
                scaler.reactiveMaskTexture = reactive.texture
                scaler.outputTexture = output.texture
                scaler.inputContentWidth = color.texture.width
                scaler.inputContentHeight = color.texture.height
                scaler.jitterOffsetX = jitter.x
                scaler.jitterOffsetY = jitter.y
                // The shader writes current-to-previous top-left UV displacement, without jitter.
                scaler.motionVectorScaleX = Float(color.texture.width)
                scaler.motionVectorScaleY = Float(color.texture.height)
                scaler.isDepthReversed = false
                scaler.preExposure = 1
                scaler.reset =
                    reset
                    || needsReset.withLock { value in
                        defer { value = false }
                        return value
                    }
                defer {
                    scaler.colorTexture = nil
                    scaler.depthTexture = nil
                    scaler.motionTexture = nil
                    scaler.reactiveMaskTexture = nil
                    scaler.outputTexture = nil
                }
                command.commandBuffer.addCompletedHandler { [self] completed in
                    if completed.status == .error { needsReset.withLock { $0 = true } }
                }
                scaler.encode(commandBuffer: command.commandBuffer)
                return true
            }
        }
    }
#endif
