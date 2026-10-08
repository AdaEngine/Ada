//
//  MetalSpatialScaler.swift
//  AdaEngine
//

#if METAL && canImport(MetalFX) && (os(macOS) || os(iOS))
    import Metal
    @unsafe @preconcurrency import MetalFX
    import Synchronization

    final class MetalSpatialScalerCache: Sendable {
        private static let maximumCachedScalers = 8

        private struct Key: Hashable {
            let inputWidth: Int
            let inputHeight: Int
            let outputWidth: Int
            let outputHeight: Int
            let inputFormat: UInt
            let outputFormat: UInt
        }

        private let scalers = Mutex<[Key: any MTLFXSpatialScaler]>([:])

        func encode(
            source: MTLTexture,
            destination: MTLTexture,
            commandBuffer: MTLCommandBuffer
        ) -> Bool {
            guard
                source.width <= destination.width,
                source.height <= destination.height,
                source.width < destination.width || source.height < destination.height,
                destination.storageMode == .private
            else {
                return false
            }

            let key = Key(
                inputWidth: source.width,
                inputHeight: source.height,
                outputWidth: destination.width,
                outputHeight: destination.height,
                inputFormat: source.pixelFormat.rawValue,
                outputFormat: destination.pixelFormat.rawValue
            )

            return scalers.withLock { scalers in
                let scaler: any MTLFXSpatialScaler
                if let cached = scalers[key] {
                    scaler = cached
                } else {
                    let descriptor = MTLFXSpatialScalerDescriptor()
                    descriptor.colorTextureFormat = source.pixelFormat
                    descriptor.outputTextureFormat = destination.pixelFormat
                    descriptor.inputWidth = source.width
                    descriptor.inputHeight = source.height
                    descriptor.outputWidth = destination.width
                    descriptor.outputHeight = destination.height
                    descriptor.colorProcessingMode = .perceptual

                    guard let created = descriptor.makeSpatialScaler(device: commandBuffer.device) else {
                        return false
                    }
                    if scalers.count >= Self.maximumCachedScalers,
                        let staleKey = scalers.keys.first {
                        scalers[staleKey] = nil
                    }
                    scaler = created
                    scalers[key] = created
                }

                guard
                    source.usage.isSuperset(of: scaler.colorTextureUsage),
                    destination.usage.isSuperset(of: scaler.outputTextureUsage)
                else {
                    return false
                }

                scaler.colorTexture = source
                scaler.outputTexture = destination
                defer {
                    // The command buffer retains encoded resources. Avoid keeping old
                    // drawables alive through cached scaler instances after a resize.
                    scaler.colorTexture = nil
                    scaler.outputTexture = nil
                }
                scaler.inputContentWidth = source.width
                scaler.inputContentHeight = source.height
                scaler.encode(commandBuffer: commandBuffer)
                return true
            }
        }
    }
#endif
