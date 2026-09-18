//
//  MetalVertexBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/31/23.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    @unsafe @preconcurrency import WebGPU

    @_spi(Internal)
    public final class WGPUVertexBuffer: WGPUBuffer, VertexBuffer, @unchecked Sendable {
        public var binding: Int

        init(buffer: WebGPU.GPUBuffer, device: WebGPU.GPUDevice, binding: Int) {
            self.binding = binding
            super.init(buffer: buffer, device: device)
        }
    }
#endif
