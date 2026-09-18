//
//  MetalSampler.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/22/23.
//

#if WEBGPU_ENABLED && canImport(WebGPU)
    @unsafe @preconcurrency import WebGPU

    final class WGPUSampler: Sampler, @unchecked Sendable {
        let descriptor: SamplerDescriptor
        let wgpuSampler: WebGPU.GPUSampler

        init(descriptor: SamplerDescriptor, wgpuSampler: WebGPU.GPUSampler) {
            self.descriptor = descriptor
            self.wgpuSampler = wgpuSampler
        }
    }

    extension SamplerMinMagFilter {
        var toWebGPU: WebGPU.GPUFilterMode {
            switch self {
            case .nearest: return .nearest
            case .linear: return .linear
            }
        }
    }

    extension SamplerMipFilter {
        var toWebGPU: WebGPU.GPUMipmapFilterMode {
            switch self {
            case .nearest: return .nearest
            case .linear: return .linear
            case .notMipmapped: return .nearest
            }
        }
    }

#endif
