#if WEBGPU_ENABLED && canImport(WebGPU)
    enum WGPUBindingKind {
        case uniformBuffer
        case texture
        case sampler
    }

    struct WGPUBindingKey: Hashable {
        let slot: Int
        let owner: ObjectIdentifier
        var offset: Int = 0
        var size: UInt64 = 0
    }

    struct WGPUBindGroupKey: Hashable {
        let set: Int
        let bindings: [WGPUBindingKey]
    }
#endif
