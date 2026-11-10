#if WEBGPU_ENABLED && canImport(WebGPU)
    import Synchronization

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

    /// Counts command-buffer submissions. Short-lived binding caches age their entries by it.
    enum WGPUSubmissionEpoch {
        private static let counter = Atomic<UInt64>(0)
        static var current: UInt64 { counter.load(ordering: .relaxed) }
        static func advance() { counter.add(1, ordering: .relaxed) }
    }
#endif
