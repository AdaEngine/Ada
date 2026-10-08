//
//  MetalCommandQueue.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if canImport(Metal)
    import Metal

    final class MetalCommandQueue: CommandQueue {
        let commandQueue: MTLCommandQueue
        #if canImport(MetalFX) && (os(macOS) || os(iOS))
            private let spatialScalerCache = MetalSpatialScalerCache()
        #endif

        init(commandQueue: MTLCommandQueue) {
            self.commandQueue = commandQueue
        }

        func makeCommandBuffer() -> CommandBuffer {
            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                fatalError("MetalCommandQueue failed. Can't create MTLCommandBuffer.")
            }
            #if canImport(MetalFX) && (os(macOS) || os(iOS))
                return MetalCommandEncoder(
                    commandBuffer: commandBuffer,
                    device: commandQueue.device,
                    spatialScalerCache: spatialScalerCache
                )
            #else
                return MetalCommandEncoder(commandBuffer: commandBuffer, device: commandQueue.device)
            #endif
        }
    }
#endif
