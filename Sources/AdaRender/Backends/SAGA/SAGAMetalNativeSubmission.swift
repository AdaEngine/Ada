#if SAGA_METAL_NATIVE_PASS
import Metal
import SAGACore
import SAGAMetal
import SAGAShaderIR
import SAGATypes

extension MetalInterop {
    public enum NativePassAccess: Sendable {
        case read
        case write
        case readWrite

        fileprivate var saga: NativePass.Access {
            switch self {
            case .read: .read
            case .write: .write
            case .readWrite: .readWrite
            }
        }
    }

    public struct NativePassUse<Resource: Sendable>: Sendable {
        public let resource: Resource
        public let access: NativePassAccess

        public init(_ resource: Resource, access: NativePassAccess = .read) {
            self.resource = resource
            self.access = access
        }
    }

    public enum NativePassError: Error, Equatable {
        case unsupportedRenderer
        case foreignResource
        case unavailableDevice
    }

    public static func supportsSAGAMetalPass(on device: any RenderDevice) -> Bool {
        (device as? SAGARenderDevice)?.context.shaderOutput == .msl
    }

    /// Records platform commands after earlier renderer work and waits for GPU retirement.
    /// The native resource arrays follow the order of the declared uses. They are valid during `record`.
    /// `onCommitted` runs on the main actor when Metal receives the command buffer.
    @MainActor
    public static func submitSAGAMetalPass(
        on device: any RenderDevice,
        label: String,
        textures: [NativePassUse<Texture>] = [],
        buffers: [NativePassUse<any Buffer>] = [],
        onCommitted: @escaping @MainActor @Sendable () -> Void = {},
        record: @escaping @MainActor @Sendable (any MTLCommandBuffer, [any MTLTexture], [any MTLBuffer]) throws -> Void
    ) async throws {
        guard let device = device as? SAGARenderDevice, device.context.shaderOutput == .msl else {
            throw NativePassError.unsupportedRenderer
        }
        let context = device.context
        let textures = try textures.map { use in
            guard let texture = use.resource.gpuTexture as? SAGAGPUTexture, texture.context === context else {
                throw NativePassError.foreignResource
            }
            return (texture, use.access.saga)
        }
        let buffers = try buffers.map { use in
            guard let buffer = use.resource as? SAGABuffer, buffer.context === context else {
                throw NativePassError.foreignResource
            }
            if case .read = use.access {
                // Reading does not invalidate the tracked generation.
            } else {
                buffer.excludeFromShadowCache()
            }
            return (buffer, use.access.saga)
        }

        try await withCheckedThrowingContinuation { (completion: CheckedContinuation<Void, any Error>) in
            context.queue.enqueue(onUnavailable: { completion.resume(throwing: NativePassError.unavailableDevice) }) { saga in
                do {
                    let textureUses = try textures.map { try NativePass.Use($0.0.slot.get(), $0.1) }
                    let bufferUses = try buffers.map { try NativePass.Use($0.0.slot.get(), $0.1) }
                    let pass = NativePass.onMainActor(label: label, uses: textureUses + bufferUses) { context in
                        guard let metal = context as? MetalNativePassContext else {
                            throw NativePassError.unsupportedRenderer
                        }
                        let nativeTextures = try textureUses.map { try metal.texture($0.resource) }
                        let nativeBuffers = try bufferUses.map { try metal.buffer($0.resource) }
                        try record(metal.commandBuffer, nativeTextures, nativeBuffers)
                        metal.addCommittedHandler(onCommitted)
                    }
                    _ = try await saga.submitCommands([.native(pass)]).wait()
                    completion.resume()
                } catch {
                    completion.resume(throwing: error)
                }
            }
        }
    }
}
#endif
