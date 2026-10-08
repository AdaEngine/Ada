import AdaAssets
import AdaUtils
import Foundation
import Math

/// Source-backed WebGPU UI material. ABI 1 reserves group 0/binding 2 for the engine view transform;
/// group 1 contains `parameters: vec4<f32>` at 0, `image` at 1 and `imageSampler` at 2.
/// Parameter state is protected by a lock; GPU updates follow the existing material render lifecycle.
public final class RuntimeWGSLMaterial: Material, @unchecked Sendable {
    private let fragmentSource: String
    private let texture: Texture2D
    private let lock = NSLock()
    private var value = Vector4.zero
    private var module: ShaderModule?

    public init(fragmentSource: String, texture: Texture2D) {
        self.fragmentSource = fragmentSource
        self.texture = texture
        let source = ShaderSource()
        source.setSource(fragmentSource, for: .fragment)
        super.init(shaderSource: source)
    }

    public required convenience init(from _: AssetDecoder) throws {
        throw RuntimeMaterialError.explicitSourcesRequired
    }

    public func setParameters(_ parameters: Vector4) {
        lock.withLock { value = parameters }
        update()
    }

    override public func update() {
        setValue(lock.withLock { value }, for: "parameters")
        setTexture(MaterialTexture(texture: texture, samplerName: "imageSampler"), for: "image")
    }

    override public func collectDefines(for _: VertexDescriptor, keys _: Set<String>) -> [ShaderDefine] { [] }

    override public func makeShaderModule(defines _: [ShaderDefine]) throws -> ShaderModule {
        if let module {
            return module
        }
        guard unsafe RenderEngine.shared.type == .webgpu else {
            throw RuntimeMaterialError.webGPURequired
        }
        var vertexReflection = ShaderReflectionData()
        let view = ShaderResource.ShaderBuffer(name: "view", size: 192, shaderStage: .vertex, binding: 2, resourceAccess: .read, members: [:])
        vertexReflection.shaderBuffers[view.name] = view
        vertexReflection.descriptorSets = [.init()]
        vertexReflection.descriptorSets[0].uniformsBuffers[2] = view

        var reflection = ShaderReflectionData()
        let parameters = ShaderResource.ShaderBuffer(name: "parameters", size: 16, shaderStage: .fragment, binding: 0, resourceAccess: .read, members: [:])
        let image = ShaderResource.ImageSampler(name: "image", binding: 1, textureType: .texture2D, descriptorSet: 1, arraySize: 1, shaderStage: .fragment, resourceAccess: .read)
        let sampler = ShaderResource.Sampler(name: "imageSampler", binding: 2, shaderStage: .fragment)
        reflection.shaderBuffers[parameters.name] = parameters
        reflection.resources[image.name] = image
        reflection.samplers[sampler.name] = sampler
        reflection.descriptorSets = [.init(), .init()]
        reflection.descriptorSets[1].uniformsBuffers[0] = parameters
        reflection.descriptorSets[1].sampledImages[1] = image
        reflection.descriptorSets[1].samplers[2] = sampler
        let vertex = Shader(source: Self.vertexSource, entryPoint: "player_vertex", stage: .vertex, reflectionData: vertexReflection)
        let fragment = Shader(source: fragmentSource, entryPoint: "player_fragment", stage: .fragment, reflectionData: reflection)
        try vertex.compile()
        try fragment.compile()
        // The engine owns the view UBO. Only material-owned bindings belong in MaterialStorage.
        let module = ShaderModule(shaders: [.vertex: vertex, .fragment: fragment], reflectionData: reflection)
        self.module = module
        return module
    }

    override public func configureRenderPipeline(for vertexDescriptor: VertexDescriptor, keys _: Set<String>, shaderModule: ShaderModule) -> RenderPipelineDescriptor? {
        guard let vertex = shaderModule.getShader(for: .vertex), let fragment = shaderModule.getShader(for: .fragment) else {
            return nil
        }
        var descriptor = RenderPipelineDescriptor(vertex: vertex)
        descriptor.debugName = "Runtime WGSL UI material"
        descriptor.fragment = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.backfaceCulling = false
        descriptor.colorAttachments = [.init(format: .bgra8, isBlendingEnabled: true)]
        return descriptor
    }

    private static let vertexSource = """
        struct View { projection: mat4x4<f32>, viewProjection: mat4x4<f32>, viewMatrix: mat4x4<f32> }
        @group(0) @binding(2) var<uniform> view: View;
        struct Output { @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32> }
        @vertex fn player_vertex(@location(0) position: vec4<f32>, @location(1) color: vec4<f32>, @location(2) uv: vec2<f32>) -> Output {
            var result: Output;
            result.position = view.viewProjection * position;
            result.uv = uv;
            return result;
        }
        """

    private enum RuntimeMaterialError: Error { case explicitSourcesRequired, webGPURequired }
}
