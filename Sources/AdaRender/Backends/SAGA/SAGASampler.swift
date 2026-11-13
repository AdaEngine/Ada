//
//  SAGASampler.swift
//  AdaEngine
//

#if SAGA_RENDER && canImport(SAGACompiler)
    import SAGA
    import SAGACore
    import SAGATypes

    @_spi(Internal)
    public final class SAGASampler: Sampler, @unchecked Sendable {
        public let descriptor: SamplerDescriptor
        let context: SAGAContext
        let slot: ResourceSlot<ResourceID>

        init(context: SAGAContext, descriptor: SamplerDescriptor) {
            self.context = context
            self.descriptor = descriptor
            self.slot = context.createSampler(descriptor.sagaDescriptor)
        }

        deinit {
            let slot = self.slot
            context.queue.enqueue { device in
                if let id = try? slot.get() {
                    try await device.destroySampler(id)
                }
            }
        }
    }

    extension SamplerDescriptor {
        var sagaDescriptor: SAGATypes.SamplerDescriptor {
            SAGATypes.SamplerDescriptor(
                addressModeU: addressModeU.saga,
                addressModeV: addressModeV.saga,
                addressModeW: addressModeW.saga,
                minFilter: minFilter.saga,
                magFilter: magFilter.saga,
                mipmapFilter: mipFilter.sagaMip,
                lodMinClamp: lodMinClamp,
                lodMaxClamp: mipFilter == .notMipmapped ? 0 : lodMaxClamp
            )
        }
    }

    extension SamplerAddressMode {
        fileprivate var saga: SAGATypes.SamplerAddressMode {
            switch self {
            case .clampToEdge: .clampToEdge
            case .repeat: .repeat
            case .mirroredRepeat: .mirrorRepeat
            }
        }
    }

    extension SamplerMinMagFilter {
        fileprivate var saga: SamplerFilter {
            switch self {
            case .nearest: .nearest
            case .linear: .linear
            }
        }
    }

    extension SamplerMipFilter {
        fileprivate var sagaMip: SamplerFilter {
            switch self {
            case .linear: .linear
            case .nearest, .notMipmapped: .nearest
            }
        }
    }
#endif
