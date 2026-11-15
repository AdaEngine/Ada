#if os(macOS) && canImport(SAGAMetal)
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
    @Suite("Editor agent activity SAGA Metal rendering", .serialized, .enabled(if: MTLCreateSystemDefaultDevice() != nil))
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
        let backend: SAGAMetalRenderBackend
        let pipeline: any RenderPipeline
        let material: CustomMaterial<EditorAgentGlowMaterial>

        init() throws {
            if unsafe RenderEngine.shared == nil {
                unsafe RenderEngine.configurations.preferredBackend = .headless
                try RenderEngine.setupRenderEngine()
            }
            backend = try SAGAMetalRenderBackend()
            material = CustomMaterial(EditorAgentGlowMaterial())
            let module = try material.makeShaderModule(defines: [])
            let storage = MaterialStorageData()
            storage.updateUniformBuffers(from: module)
            unsafe MaterialStorage.shared.setMaterialData(storage, for: material)
            material.update()
            let file = try #require(Bundle.editor.url(forResource: "agent_activity", withExtension: "wesl", subdirectory: "Assets/Shaders"))
            let linked = try ShaderModule.linkWESL(from: file)
            let saga = try ShaderModule.createModule(from: linked, device: backend.renderDevice)
            var vertexDescriptor = VertexDescriptor()
            vertexDescriptor.attributes.append([
                .attribute(.vector4, name: "a_Position"), .attribute(.vector4, name: "a_Color"), .attribute(.vector2, name: "a_TexCoordinate"),
            ])
            vertexDescriptor.layouts[0].stride = MemoryLayout<QuadVertexData>.stride
            let descriptor = try EditorAgentGlowMaterial.configurePipeline(
                keys: [],
                vertex: try #require(saga.getShader(for: .vertex)),
                fragment: try #require(saga.getShader(for: .fragment)),
                vertexDescriptor: vertexDescriptor
            )
            pipeline = backend.renderDevice.createRenderPipeline(from: descriptor)
        }

        func render(state: EditorAgentActivityState, time: Float) async throws -> [UInt8] {
            let device = backend.renderDevice
            let target = Texture2D(
                gpuTexture: device.createTexture(from: .init(
                    width: 320, height: 200, pixelFormat: .bgra8,
                    textureUsage: [.renderTarget, .read], textureType: .texture2D
                )),
                sampler: device.createSampler(from: .init()), size: [320, 200]
            )
            let command = device.createCommandQueue().makeCommandBuffer()
            let encoder = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .clear)
            ]))
            encoder.setRenderPipelineState(pipeline)
            let positions: [Vector2] = [[-1, 1], [1, 1], [-1, -1], [-1, -1], [1, 1], [1, -1]]
            let vertices = positions.map { point in
                QuadVertexData(
                    position: [point.x, point.y, 0, 1],
                    color: .white,
                    textureCoordinate: [(point.x + 1) / 2, (1 - point.y) / 2],
                    textureIndex: 0
                )
            }
            var vertexData = BufferData(label: "Editor glow probe vertices", elements: vertices)
            vertexData.write(to: device)
            encoder.setVertexBuffer(vertexData, offset: 0, slot: 0)
            let view = GlobalViewUniform(projectionMatrix: .identity, viewProjectionMatrix: .identity)
            encoder.setVertexBuffer(view, slot: GlobalBufferIndex.viewUniform)
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
            var parameters = BufferData(label: "Editor glow probe parameters", elements: [uploaded])
            parameters.write(to: device)
            encoder.setFragmentBuffer(parameters, offset: 0, slot: 0)
            encoder.draw(type: .triangle, vertexStart: 0, vertexCount: 6, instanceCount: 1)
            encoder.endRenderPass()
            command.commit()
            let image = try #require(try await device.readImage(from: target))
            #expect(backend.context.errorLog.all.isEmpty, "\(backend.context.errorLog.all)")
            return Array(image.data)
        }
    }
#endif
