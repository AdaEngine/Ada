#if canImport(Metal)
    import AdaAssets
    import AdaCorePipelines
    @_spi(Internal) @testable import AdaRender
    import AdaUtils
    import Foundation
    import Math
    @preconcurrency import Metal
    import Testing

    @testable import AdaEditor

    @MainActor
    @Suite("Editor agent activity Metal rendering", .serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
    struct EditorAgentActivityRenderTests {
        @Test("The native shader renders semantic edge colors and a transparent center")
        func statusPixels() async throws {
            let probe = try AgentGlowMetalProbe()
            for state in [EditorAgentActivityState.working, .completed, .needsInput, .failed] {
                let pixels = try await probe.render(state: state, time: 5)
                let edge = (100 * 320 + 1) * 4
                let center = (100 * 320 + 160) * 4
                let blue = pixels[edge]
                let green = pixels[edge + 1]
                let red = pixels[edge + 2]
                #expect(pixels[edge + 3] > 20)
                #expect(pixels[center + 3] == 0)
                switch state {
                case .working: #expect(blue > red && blue > green)
                case .completed: #expect(green > red && green > blue)
                case .needsInput: #expect(red > blue && green > blue)
                case .failed: #expect(red > green && red > blue)
                case .idle: break
                }
            }
            let before = try await probe.render(state: .working, time: 1)
            let after = try await probe.render(state: .working, time: 4)
            #expect(before != after)
        }
    }

    @MainActor
    private final class AgentGlowMetalProbe {
        let device: MTLDevice
        let pipeline: MetalRenderPipeline
        let material: CustomMaterial<EditorAgentGlowMaterial>

        init() throws {
            if unsafe RenderEngine.shared == nil {
                unsafe RenderEngine.configurations.preferredBackend = .headless
                try RenderEngine.setupRenderEngine()
            }
            let renderDevice = try #require(MTLCreateSystemDefaultDevice())
            device = renderDevice
            material = CustomMaterial(EditorAgentGlowMaterial())
            let module = try ShaderCompiler(shaderSource: material.shaderSource).compileShaderModule()
            let storage = MaterialStorageData()
            storage.updateUniformBuffers(from: module)
            unsafe MaterialStorage.shared.setMaterialData(storage, for: material)
            material.update()
            func compile(_ stage: ShaderStage, source: AssetHandle<ShaderSource>) throws -> Shader {
                let spirv = try ShaderCompiler(shaderSource: source.asset).compileSpirvBin(for: stage, ignoreCache: true)
                let result = try SpirvCompiler(spriv: spirv.data, stage: stage, deviceLang: .msl).compile()
                let shader = Shader(source: result.source, entryPoint: try #require(result.entryPoints.first?.name), stage: stage, reflectionData: result.reflection)
                shader.compiledShader = try MetalShader(shader: shader, device: renderDevice)
                return shader
            }
            var vertexDescriptor = VertexDescriptor()
            vertexDescriptor.attributes.append([
                .attribute(.vector4, name: "a_Position"), .attribute(.vector4, name: "a_Color"), .attribute(.vector2, name: "a_TexCoordinate"),
            ])
            vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertexData>.stride
            let descriptor = try EditorAgentGlowMaterial.configurePipeline(
                keys: [],
                vertex: compile(.vertex, source: EditorAgentGlowMaterial.vertexShader()),
                fragment: compile(.fragment, source: EditorAgentGlowMaterial.fragmentShader()),
                vertexDescriptor: vertexDescriptor
            )
            pipeline = try MetalRenderPipeline(descriptor: descriptor, device: device)
        }

        func render(state: EditorAgentActivityState, time: Float) async throws -> [UInt8] {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 320, height: 200, mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = [.renderTarget]
            let target = try #require(device.makeTexture(descriptor: descriptor))
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = target
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
            let queue = try #require(device.makeCommandQueue())
            let command = try #require(queue.makeCommandBuffer())
            let encoder = try #require(command.makeRenderCommandEncoder(descriptor: pass))
            encoder.setRenderPipelineState(pipeline.renderPipeline)
            let positions: [Vector2] = [[-1, 1], [1, 1], [-1, -1], [-1, -1], [1, 1], [1, -1]]
            let vertices = positions.map { point in
                QuadVertexData(
                    position: [point.x, point.y, 0, 1],
                    color: .white,
                    textureCoordinate: [(point.x + 1) / 2, (1 - point.y) / 2],
                    textureIndex: 0
                )
            }
            try vertices.withUnsafeBytes { bytes in
                encoder.setVertexBytes(try #require(bytes.baseAddress), length: bytes.count, index: 0)
            }
            let transforms = [Transform3D.identity, .identity, .identity]
            try transforms.withUnsafeBytes { bytes in
                encoder.setVertexBytes(try #require(bytes.baseAddress), length: bytes.count, index: 2)
            }
            let color = state.color(accent: .blue)
            material.parameters = EditorAgentGlowParameters(
                color: color,
                geometry: Vector4(320, 200, time, 42),
                style: Vector4(state.intensity, state == .working ? 0.065 : 0.012, 14, 1)
            )
            // Read the bytes actually uploaded by CustomMaterial, rather than bypassing its binding path.
            let uploaded = try #require(material.getValue(for: "EditorAgentGlowMaterial", type: EditorAgentGlowParameters.self))
            #expect(uploaded.color == color)
            #expect(uploaded.geometry.z == time)
            withUnsafeBytes(of: uploaded) { bytes in
                if let address = bytes.baseAddress {
                    encoder.setFragmentBytes(address, length: bytes.count, index: 0)
                }
            }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 6)
            encoder.endEncoding()
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { _ in continuation.resume() }
                command.commit()
            }
            #expect(command.status == .completed)
            var pixels = [UInt8](repeating: 0, count: 320 * 200 * 4)
            target.getBytes(&pixels, bytesPerRow: 320 * 4, from: MTLRegionMake2D(0, 0, 320, 200), mipmapLevel: 0)
            return pixels
        }
    }
#endif
