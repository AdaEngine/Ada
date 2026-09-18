//
//  MetalSampler.swift
//  AdaEngine
//
//  Created by v.prusakov on 1/22/23.
//

#if METAL
    @unsafe @preconcurrency import Metal

    final class MetalSampler: Sampler, Sendable {
        let descriptor: SamplerDescriptor
        let mtlSampler: MTLSamplerState

        init(descriptor: SamplerDescriptor, device: MTLDevice) {
            let mtlDescriptor = MTLSamplerDescriptor()
            mtlDescriptor.minFilter = descriptor.minFilter.toMetal
            mtlDescriptor.magFilter = descriptor.magFilter.toMetal
            mtlDescriptor.lodMinClamp = descriptor.lodMinClamp
            mtlDescriptor.lodMaxClamp = descriptor.lodMaxClamp
            mtlDescriptor.supportArgumentBuffers = true

            switch descriptor.mipFilter {
            case .nearest:
                mtlDescriptor.mipFilter = .nearest
            case .linear:
                mtlDescriptor.mipFilter = .linear
            case .notMipmapped:
                mtlDescriptor.mipFilter = .notMipmapped
            }

            self.descriptor = descriptor
            guard let sampler = device.makeSamplerState(descriptor: mtlDescriptor) else {
                preconditionFailure("Metal failed to create a sampler state.")
            }
            self.mtlSampler = sampler
        }
    }

#endif
