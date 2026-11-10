#if canImport(WebGPU) && !os(WASI) && !os(Android)
@_spi(Internal) @testable import AdaRender
import Foundation
import Math
import Testing

@MainActor
@Suite("WebGPU retained binding state", .serialized)
struct WGPUBindingStateTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func changesTrackIdentityRangeTextureAndSampler() throws {
        let device = try makeDevice()
        let first = try #require(device.createUniformBuffer(Vector4.self, count: 32, binding: 2) as? WGPUBuffer)
        let second = try #require(device.createUniformBuffer(Vector4.self, count: 32, binding: 2) as? WGPUBuffer)
        var resources = WGPURenderCommandEncoder.BindGroupResources()
        let changed1 = resources.setUniform(first, offset: 0, size: 256, slot: 2)
        #expect(changed1)
        let changed2 = resources.setUniform(first, offset: 0, size: 256, slot: 2)
        #expect(!changed2)
        let changed3 = resources.setUniform(first, offset: 256, size: 256, slot: 2)
        #expect(changed3)
        let changed4 = resources.setUniform(second, offset: 256, size: 256, slot: 2)
        #expect(changed4)
        let changed5 = resources.setUniform(second, offset: 0, size: 512, slot: 2)
        #expect(changed5)
        let changed6 = resources.setUniform(second, offset: 0, size: 512, slot: 2)
        #expect(!changed6)
        let white = Texture2D(image: Image(width: 1, height: 1, color: .white))
        let black = Texture2D(image: Image(width: 1, height: 1, color: .black))
        let whiteGPU = try #require(white.gpuTexture as? WGPUGPUTexture)
        let blackGPU = try #require(black.gpuTexture as? WGPUGPUTexture)
        let sampler = try #require(white.sampler as? WGPUSampler)
        let changed7 = resources.setTexture(whiteGPU, slot: 4)
        #expect(changed7)
        let changed8 = resources.setTexture(whiteGPU, slot: 4)
        #expect(!changed8)
        let changed9 = resources.setSampler(sampler, slot: 7)
        #expect(changed9)
        let changed10 = resources.setSampler(sampler, slot: 7)
        #expect(!changed10)
        let changed11 = resources.setTexture(blackGPU, slot: 4)
        #expect(changed11)
        let changed12 = resources.setSampler(sampler, slot: 7)
        #expect(!changed12)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func rendersChangedBindingsOffsetsAndPipelineSwitches() async throws {
        let device = try makeDevice()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("bindings.glsl")
        try """
        #version 450 core
        #pragma stage : vert
        [[main]]
        void binding_vertex() {
            vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
            gl_Position = vec4(p[gl_VertexIndex], 0, 1);
        }
        #version 450 core
        #pragma stage : frag
        layout(binding=2) uniform Tint { vec4 u_Color; };
        layout(location=0) out vec4 o_Color;
        [[main]]
        void binding_fragment() { o_Color = u_Color; }
        """.write(to: source, atomically: true, encoding: .utf8)
        let module = try ShaderCompiler(from: source).compileShaderModule()
        var descriptor = RenderPipelineDescriptor(
            vertex: try #require(module.getShader(for: .vertex)),
            fragment: try module.getShader(for: .fragment),
            debugName: "Retained bindings A", backfaceCulling: false,
            colorAttachments: [.init(format: .rgba8)]
        )
        let firstPipeline = device.createRenderPipeline(from: descriptor)
        descriptor.debugName = "Retained bindings B"
        let secondPipeline = device.createRenderPipeline(from: descriptor)
        let colors = device.createUniformBuffer(Vector4.self, count: 32, binding: 2)
        var values = [Vector4](repeating: [1, 0, 0, 1], count: 32)
        values[16] = [0, 1, 0, 1]
        colors.setElements(&values)
        let blue = device.createUniformBuffer(Vector4.self, binding: 2)
        blue.setData(Vector4(0, 0, 1, 1))
        let target = RenderTexture(size: [8, 4], scaleFactor: 1, format: .rgba8)
        let command = device.createCommandQueue().makeCommandBuffer()
        let pass = command.beginRenderPass(.init(colorAttachments: [
            .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
        ]))
        pass.setViewport(Rect(x: 0, y: 0, width: 8, height: 4))
        pass.setRenderPipelineState(firstPipeline)
        for x in [0, 2] {
            pass.setFragmentBuffer(colors, offset: 0, slot: 2)
            pass.setScissorRect(Rect(x: Float(x), y: 0, width: 2, height: 4))
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        }
        pass.setFragmentBuffer(colors, offset: 256, slot: 2)
        pass.setRenderPipelineState(secondPipeline)
        pass.setScissorRect(Rect(x: 4, y: 0, width: 2, height: 4))
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.setFragmentBuffer(blue, offset: 0, slot: 2)
        pass.setScissorRect(Rect(x: 6, y: 0, width: 2, height: 4))
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        pass.setRenderPipelineState(firstPipeline)
        pass.setScissorRect(Rect(x: 0, y: 2, width: 2, height: 2))
        pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        let nativePipeline = try #require(firstPipeline as? WGPURenderPipeline)
        let cachedCount = nativePipeline.cachedBindGroupCount
        #expect(cachedCount > 0)
        pass.setScissorRect(Rect(x: 6, y: 2, width: 2, height: 2))
        for _ in 0..<32 {
            pass.setVertexBuffer(Vector4(1, 1, 0, 1), slot: 2)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
        }
        #expect(nativePipeline.cachedBindGroupCount == cachedCount)
        pass.endRenderPass()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { continuation.resume() }
            command.commit()
        }
        let image = try #require(try await device.readImage(from: target))
        #expect(image.getPixel(x: 0, y: 0) == .red)
        #expect(image.getPixel(x: 0, y: 3) == .blue)
        #expect(image.getPixel(x: 3, y: 2) == .red)
        #expect(image.getPixel(x: 5, y: 2) == .green)
        #expect(image.getPixel(x: 7, y: 0) == .blue)
        #expect(image.getPixel(x: 7, y: 3) == .init(red: 1, green: 1, blue: 0, alpha: 1))
    }

    /// Shadow passes select each batch's instances with `firstInstance` instead of rebinding the
    /// instance buffer at a new offset for every draw.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func indexedDrawsReadInstanceDataFromTheFirstInstance() async throws {
        let device = try makeDevice()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("first-instance.glsl")
        try """
        #version 450 core
        #pragma stage : vert
        layout(location=0) in vec4 a_Color;
        layout(location=0) out vec4 v_Color;
        [[main]]
        void first_instance_vertex() {
            vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
            v_Color = a_Color;
            gl_Position = vec4(p[gl_VertexIndex], 0, 1);
        }
        #version 450 core
        #pragma stage : frag
        layout(location=0) in vec4 v_Color;
        layout(location=0) out vec4 o_Color;
        [[main]]
        void first_instance_fragment() { o_Color = v_Color; }
        """.write(to: source, atomically: true, encoding: .utf8)
        let module = try ShaderCompiler(from: source).compileShaderModule()
        var vertex = VertexDescriptor()
        vertex.attributes[0] = .attribute(.vector4, name: "color", bufferIndex: 0, offset: 0)
        vertex.layouts[0] = .init(stride: MemoryLayout<Vector4>.stride, stepFunction: .perInstance)
        let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
            vertex: try #require(module.getShader(for: .vertex)),
            fragment: try module.getShader(for: .fragment),
            debugName: "First instance",
            backfaceCulling: false,
            vertexDescriptor: vertex,
            colorAttachments: [.init(format: .rgba8)]
        ))
        var colors: [Vector4] = [[1, 0, 0, 1], [0, 1, 0, 1], [0, 0, 1, 1], [1, 1, 0, 1]]
        let instances = device.createVertexBuffer(label: "First instance colors", length: MemoryLayout<Vector4>.stride * colors.count, binding: 0)
        unsafe colors.withUnsafeMutableBytes { unsafe instances.setData($0.baseAddress!, byteCount: $0.count, offset: 0) }
        var indices: [UInt32] = [0, 1, 2]
        let indexBuffer = unsafe indices.withUnsafeBytes {
            unsafe device.createIndexBuffer(label: "First instance indices", format: .uInt32, bytes: $0.baseAddress!, length: $0.count)
        }
        let target = RenderTexture(size: [8, 2], scaleFactor: 1, format: .rgba8)
        let command = device.createCommandQueue().makeCommandBuffer()
        let pass = command.beginRenderPass(.init(colorAttachments: [
            .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
        ]))
        pass.setViewport(Rect(x: 0, y: 0, width: 8, height: 2))
        pass.setRenderPipelineState(pipeline)
        pass.setVertexBuffer(instances, offset: 0, slot: 0)
        pass.setIndexBuffer(indexBuffer, offset: 0)
        for instance in colors.indices.reversed() {
            pass.setScissorRect(Rect(x: Float(instance * 2), y: 0, width: 2, height: 2))
            pass.drawIndexed(indexCount: 3, indexBufferOffset: 0, instanceCount: 1, firstInstance: instance)
        }
        pass.endRenderPass()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            command.addCompletedHandler { continuation.resume() }
            command.commit()
        }
        let image = try #require(try await device.readImage(from: target))
        #expect(image.getPixel(x: 1, y: 1) == .red)
        #expect(image.getPixel(x: 3, y: 1) == .green)
        #expect(image.getPixel(x: 5, y: 1) == .blue)
        #expect(image.getPixel(x: 7, y: 1) == .init(red: 1, green: 1, blue: 0, alpha: 1))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_SPRITE_WGPU_SMOKE"] == "1"))
    func transientRenderAttachmentsAreNotRetainedByBindings() async throws {
        let device = try makeDevice()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("transient.glsl")
        try """
        #version 450 core
        #pragma stage : vert
        [[main]]
        void transient_vertex() {
            vec2 p[3] = vec2[](vec2(-1,-1), vec2(3,-1), vec2(-1,3));
            gl_Position = vec4(p[gl_VertexIndex], 0, 1);
        }
        #version 450 core
        #pragma stage : frag
        layout(binding=0) uniform texture2D u_Texture;
        layout(binding=1) uniform sampler u_Sampler;
        layout(location=0) out vec4 o_Color;
        [[main]]
        void transient_fragment() { o_Color = texture(sampler2D(u_Texture, u_Sampler), vec2(0.5)); }
        """.write(to: source, atomically: true, encoding: .utf8)
        let module = try ShaderCompiler(from: source).compileShaderModule()
        let pipeline = device.createRenderPipeline(from: RenderPipelineDescriptor(
            vertex: try #require(module.getShader(for: .vertex)),
            fragment: try module.getShader(for: .fragment),
            debugName: "Transient attachments",
            backfaceCulling: false,
            colorAttachments: [.init(format: .rgba8)]
        ))
        let native = try #require(pipeline as? WGPURenderPipeline)
        let target = RenderTexture(size: [2, 2], scaleFactor: 1, format: .rgba8)
        weak var lastAttachment: WGPUGPUTexture?
        for _ in 0..<8 {
            let sampled = RenderTexture(size: [2, 2], scaleFactor: 1, format: .rgba8)
            lastAttachment = sampled.gpuTexture as? WGPUGPUTexture
            let command = device.createCommandQueue().makeCommandBuffer()
            let clear = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: sampled, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
            ]))
            clear.endRenderPass()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
            ]))
            pass.setViewport(Rect(x: 0, y: 0, width: 2, height: 2))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentTexture(sampled, slot: 0)
            pass.setFragmentSamplerState(sampled.sampler, slot: 1)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            command.commit()
            let image = try #require(try await device.readImage(from: target))
            #expect(image.getPixel(x: 0, y: 0) == .red)
        }
        #expect(native.cachedBindGroupCount == 0)
        #expect(lastAttachment == nil)
    }

    private func makeDevice() throws -> any RenderDevice {
        unsafe RenderEngine.configurations.preferredBackend = .webgpu
        try RenderEngine.setupRenderEngine()
        let engine = try #require(unsafe RenderEngine.shared)
        try #require(engine.type == .webgpu)
        return engine.renderDevice
    }
}
#endif
