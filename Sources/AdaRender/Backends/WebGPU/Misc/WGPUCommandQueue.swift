//
//  MetalCommandQueue.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 23.11.2025.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    @unsafe @preconcurrency import WebGPU

    @_spi(Internal)
    public final class WGPUCommandQueue: CommandQueue {
        let device: WebGPU.GPUDevice
        private let spatialScaler: WGPUFSRSpatialScaler
        private let instance: WebGPU.GPUInstance?

        public init(device: WebGPU.GPUDevice) {
            self.device = device
            self.spatialScaler = WGPUFSRSpatialScaler()
            self.instance = nil
        }

        init(device: WebGPU.GPUDevice, spatialScaler: WGPUFSRSpatialScaler, instance: WebGPU.GPUInstance? = nil) {
            self.device = device
            self.spatialScaler = spatialScaler
            self.instance = instance
        }

        public func makeCommandBuffer() -> CommandBuffer {
            WGPUCommandEncoder(device: device, spatialScaler: spatialScaler, instance: instance)
        }
    }
#endif
