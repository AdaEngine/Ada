//
//  WGPUIndexBuffer.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/18/23.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    @unsafe @preconcurrency import WebGPU

    @_spi(Internal)
    public final class WGPUIndexBuffer: WGPUBuffer, IndexBuffer, @unchecked Sendable {
        public let indexFormat: IndexBufferFormat

        init(buffer: WebGPU.GPUBuffer, device: WebGPU.GPUDevice, indexFormat: IndexBufferFormat) {
            self.indexFormat = indexFormat

            super.init(buffer: buffer, device: device)
        }
    }

#endif
