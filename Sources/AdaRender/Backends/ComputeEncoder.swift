//
//  ComputeEncoder.swift
//  AdaEngine
//
//  Compute passes: dispatches that read and write textures and buffers outside a render pass.
//

/// Describes a compute pipeline created from a compute-stage ``Shader``.
public struct ComputePipelineDescriptor {
    /// The shader to run. Its stage must be ``ShaderStage/compute``.
    public var shader: Shader
    public var debugName: String

    public init(shader: Shader, debugName: String) {
        self.shader = shader
        self.debugName = debugName
    }
}

/// A compiled compute pipeline state.
public protocol ComputePipelineState: AnyObject, Sendable {
    var descriptor: ComputePipelineDescriptor { get }
    /// Whether the device finished creating the pipeline. Creation is asynchronous on some backends, and a dispatch of a
    /// pipeline that failed or is still pending cannot run, so callers check this and use a fallback until it is true.
    var isReady: Bool { get }
}

/// Configures a compute pass.
public struct ComputePassDescriptor {
    public var label: String?

    public init(label: String? = nil) {
        self.label = label
    }
}

/// A set of resources bound to a compute shader group.
public struct ComputeResourceSet {
    public struct Binding {
        public enum Resource {
            /// A uniform buffer, bound in full.
            case uniformBuffer(UniformBuffer)
            /// A texture sampled with `textureLoad` or a sampler. A `mipLevel` binds a single level; nil binds every level.
            case sampledTexture(Texture, mipLevel: Int?)
            /// A texture written through a `texture_storage_2d` binding. The texture needs ``Texture/Usage/storage``.
            case storageTexture(Texture, mipLevel: Int)
            case sampler(Sampler)
        }

        public let binding: Int
        public let resource: Resource

        public init(binding: Int, resource: Resource) {
            self.binding = binding
            self.resource = resource
        }
    }

    public var bindings: [Binding]

    public init(bindings: [Binding]) {
        self.bindings = bindings
    }
}

/// Records compute dispatches. Create one with ``CommandBuffer/beginComputePass(_:)``.
///
/// Dispatches run in order with the render passes recorded before and after them on the same command buffer.
public protocol ComputeCommandEncoder: AnyObject {
    /// Sets the pipeline for later dispatches.
    func setComputePipelineState(_ pipeline: any ComputePipelineState)

    /// Binds resources to the shader group at `index`. Bindings persist until replaced.
    func setResourceSet(_ resourceSet: ComputeResourceSet, index: Int)

    /// Runs `threadgroups.x * y * z` workgroups of the current pipeline.
    func dispatch(threadgroups: SIMD3<Int>)

    /// Finishes the pass.
    func endComputePass()
}

extension CommandBuffer {
    /// Begins a compute pass, or returns nil when the backend does not support compute
    /// (see ``RenderDevice/supportsComputePasses``).
    public func beginComputePass(_: ComputePassDescriptor) -> (any ComputeCommandEncoder)? { nil }
}
