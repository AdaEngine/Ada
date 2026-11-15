#if SAGA_NATIVE || (os(macOS) && SAGA_METAL_NATIVE_PASS)
@_spi(Internal) @testable import AdaRender
#if os(macOS)
import Metal
#endif
import SAGACompiler
import SAGATypes
import Testing

func sagaNativeTestDeviceAvailable() -> Bool {
    #if os(macOS)
    MTLCreateSystemDefaultDevice() != nil
    #else
    SAGAContext.isVulkanAvailable
    #endif
}

@Suite("SAGA indexed indirect rendering", .serialized)
struct SAGAIndexedIndirectTests {
    @Test(.enabled(if: sagaNativeTestDeviceAvailable()))
    func drawsUseGPUWrittenArgumentsFromTheSameCommandBuffer() async throws {
        #if os(macOS)
        let context = try SAGAMetalRenderBackend().context
        #else
        let context = try SAGAContext.vulkan(debugErrors: true)
        #endif
        let device = SAGARenderDevice(context: context)
        let shader = """
            @vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4f {
                let vertices = array(vec2f(-1, -1), vec2f(3, -1), vec2f(-1, 3));
                return vec4f(vertices[index], 0, 1);
            }
            @fragment fn fs() -> @location(0) vec4f { return vec4f(1, 0, 0, 1); }
            """
        let vertex = Shader(source: shader, entryPoint: "vs", stage: .vertex)
        let fragment = Shader(source: shader, entryPoint: "fs", stage: .fragment)
        vertex.compiledShader = try device.compileShader(from: vertex)
        fragment.compiledShader = try device.compileShader(from: fragment)
        let pipeline = device.createRenderPipeline(from: .init(
            vertex: vertex, fragment: fragment, debugName: "GPU-written indirect arguments",
            backfaceCulling: false, depthPixelFormat: .none, colorAttachments: [.init(format: .rgba8)]
        ))
        let indices: [UInt32] = [0, 1, 2]
        let index = try unsafe indices.withUnsafeBytes { bytes in
            let pointer = try #require(unsafe bytes.baseAddress)
            return unsafe device.createIndexBuffer(label: "Indirect triangle indices", format: .uInt32, bytes: pointer, length: bytes.count)
        }
        let visible = Texture2D(
            gpuTexture: device.createTexture(from: .init(
                width: 8, height: 8, pixelFormat: .rgba8, textureUsage: [.renderTarget, .read], textureType: .texture2D
            )), sampler: device.createSampler(from: .init()), size: [8, 8]
        )
        let empty = Texture2D(
            gpuTexture: device.createTexture(from: .init(
                width: 8, height: 8, pixelFormat: .rgba8, textureUsage: [.renderTarget, .read], textureType: .texture2D
            )), sampler: device.createSampler(from: .init()), size: [8, 8]
        )
        let stride = MemoryLayout<IndexedIndirectArguments>.stride
        let arguments = try #require(device.createBuffer(label: "Indirect words", length: 2 * stride, options: .storageShared) as? SAGABuffer)
        let computeSource = """
            @group(0) @binding(0) var<storage, read_write> output: array<u32>;
            @compute @workgroup_size(1) fn writeArgs() {
                output[0] = 3u;
                output[1] = 0u;
                output[5] = 3u;
                output[6] = 1u;
            }
            """
        let artifact = try IndependentShaderCompiler().compileCompute(.wgsl(computeSource), to: context.shaderOutput)
        let compute = ResourceSlot<ComputePipeline>()
        context.queue.enqueue { gpu in
            compute.fulfill(try await gpu.createComputePipeline(artifact))
        }
        let commands = SAGACommandBuffer(context: context)
        commands.append {
            .dispatchCompute(pipeline: try compute.get(), bindings: [.init(binding: 0): try arguments.slot.get()], workgroups: .init(x: 1))
        }
        for (target, offset) in [(visible, stride), (empty, 0)] {
            let pass = commands.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .black)
            ]))
            pass.setRenderPipelineState(pipeline)
            pass.setIndexBuffer(index, offset: 0)
            #expect(!pass.drawIndexedIndirect(arguments: arguments, offset: 1))
            #expect(!pass.drawIndexedIndirect(arguments: arguments, offset: stride + 4))
            #expect(pass.drawIndexedIndirect(arguments: arguments, offset: offset))
            pass.endRenderPass()
        }
        commands.commit()
        let drawn = try #require(try await device.readImage(from: visible))
        let untouched = try #require(try await device.readImage(from: empty))
        #expect(drawn.getPixel(x: 4, y: 4) == .red)
        #expect(untouched.getPixel(x: 4, y: 4) == .black)
        #expect(context.errorLog.all.isEmpty)
    }
}
#endif
