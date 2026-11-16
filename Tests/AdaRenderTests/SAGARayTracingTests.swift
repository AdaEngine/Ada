#if SAGA_NATIVE
    import AdaUtils
    import Foundation
    import Math
    import Testing

    @_spi(Internal) @testable import AdaRender

    /// Builds acceleration structures through AdaRender's API on a real Vulkan device and traces them from a fragment shader.
    @Suite(.serialized)
    struct SAGARayTracingTests {
        private static var available: Bool { SAGAContext.isVulkanAvailable }

        private static let shader = """
            enable wgpu_ray_query;
            @group(0) @binding(0) var scene: acceleration_structure;
            @vertex fn vs(@builtin(vertex_index) index: u32) -> @builtin(position) vec4<f32> {
                var corners = array<vec2<f32>, 3>(vec2<f32>(-1.0, -1.0), vec2<f32>(3.0, -1.0), vec2<f32>(-1.0, 3.0));
                return vec4<f32>(corners[index], 0.0, 1.0);
            }
            @fragment fn fs(@builtin(position) position: vec4<f32>) -> @location(0) vec4<f32> {
                var q: ray_query;
                // The left half aims at the instance (x 2...3 after its translation); the right half aims away.
                let x = select(0.25, 20.0, position.x >= 4.0);
                rayQueryInitialize(&q, scene, RayDesc(0u, 255u, 0.1, 10.0, vec3f(x + 2.0, 3.25, 0.0), vec3f(0.0, 0.0, 1.0)));
                while rayQueryProceed(&q) { rayQueryConfirmIntersection(&q); }
                let hit = rayQueryGetCommittedIntersection(&q);
                return vec4<f32>(f32(hit.kind), hit.t / 8.0, f32(hit.instance_custom_data) / 255.0, 1.0);
            }
            """

        @Test(.enabled(if: SAGARayTracingTests.available))
        func buildingThroughTheAdaRenderAPIAndTracingFromAFragmentShaderHitsTheInstance() async throws {
            let context = try SAGAContext.vulkan(debugErrors: true)
            let device = SAGARenderDevice(context: context)
            guard device.supportsRayQueries else { return }

            // Positions use a 16-byte stride (one padding float per vertex), so the stride path is exercised.
            var vertices: [Float] = [0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0]
            let vertexBuffer = unsafe vertices.withUnsafeMutableBytes { raw in
                unsafe device.createBuffer(label: "ray tracing vertices", bytes: raw.baseAddress!, length: raw.count, options: .storageShared)
            }
            let bottom = try #require(device.createAccelerationStructure(.bottomLevel(triangleCapacity: 1)))
            let top = try #require(device.createAccelerationStructure(.topLevel(instanceCapacity: 1)))
            let geometry = AccelerationStructureGeometry(vertexBuffer: vertexBuffer, vertexStride: 16, vertexCount: 3)

            let vertex = Shader(source: Self.shader, entryPoint: "vs", stage: .vertex)
            let fragment = Shader(source: Self.shader, entryPoint: "fs", stage: .fragment)
            vertex.compiledShader = try device.compileShader(from: vertex)
            fragment.compiledShader = try device.compileShader(from: fragment)
            let pipeline = device.createRenderPipeline(
                from: RenderPipelineDescriptor(
                    vertex: vertex, fragment: fragment, debugName: "fragment ray query", backfaceCulling: false,
                    depthPixelFormat: .none, colorAttachments: [.init(format: .rgba8)]
                )
            )
            let size = SizeInt(width: 8, height: 8)
            let target = Texture2D(
                gpuTexture: device.createTexture(
                    from: TextureDescriptor(width: 8, height: 8, pixelFormat: .rgba8, textureUsage: [.renderTarget, .read], textureType: .texture2D)
                ),
                sampler: device.createSampler(from: SamplerDescriptor()), size: size
            )

            let commands = device.createCommandQueue().makeCommandBuffer()
            #expect(commands.encodeBuild(of: bottom, geometry: geometry))
            let instance = AccelerationStructureInstance(
                structure: bottom, transform: .identity.translatedBy(Vector3(2, 3, 4)), mask: 1, instanceID: 73
            )
            #expect(commands.encodeBuild(of: top, instances: [instance]))
            let pass = commands.beginRenderPass(
                RenderPassDescriptor(colorAttachments: [
                    RenderPassColorAttachmentDescriptor(
                        texture: target, operation: OperationDescriptor(loadAction: .clear, storeAction: .store), clearColor: .black
                    )
                ])
            )
            pass.setRenderPipelineState(pipeline)
            pass.setResourceSet(
                RenderResourceSet(bindings: [.init(binding: 0, shaderStages: .fragment, resource: .accelerationStructure(top))]), index: 0
            )
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            commands.commit()

            let image = try #require(try await device.readImage(from: target))
            let bytes = [UInt8](image.data)
            func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(bytes[((y * 8 + x) * 4)..<((y * 8 + x) * 4 + 4)]) }
            let hit = pixel(1, 3), miss = pixel(6, 3)
            #expect(hit[0] == 255, "The aimed pixel must hit the instance: \(hit)")
            #expect(hit[2] == 73, "The hit must report the instance ID: \(hit)")
            #expect(miss[0] == 0, "The pixel aimed away must miss: \(miss)")
            await context.queue.drain()
            #expect(context.errorLog.all.isEmpty, "SAGA device errors: \(context.errorLog.all)")
        }

        @Test(.enabled(if: SAGARayTracingTests.available))
        func invalidBuildsAreRefusedWithoutReachingTheDevice() async throws {
            let context = try SAGAContext.vulkan()
            let device = SAGARenderDevice(context: context)
            guard device.supportsRayQueries else { return }
            let bottom = try #require(device.createAccelerationStructure(.bottomLevel(triangleCapacity: 1)))
            let top = try #require(device.createAccelerationStructure(.topLevel(instanceCapacity: 1)))
            let buffer = device.createBuffer(length: 36, options: .storageShared)
            let commands = device.createCommandQueue().makeCommandBuffer()
            #expect(!commands.encodeBuild(of: bottom, geometry: AccelerationStructureGeometry(vertexBuffer: buffer, vertexStride: 8, vertexCount: 3)))
            let triangle = AccelerationStructureGeometry(vertexBuffer: buffer, vertexCount: 3)
            #expect(commands.encodeBuild(of: bottom, geometry: triangle))
            #expect(!commands.encodeBuild(of: top, geometry: triangle), "A top-level structure cannot take triangles")
            #expect(!commands.encodeBuild(of: top, instances: []))
            #expect(!commands.encodeBuild(of: top, instances: [AccelerationStructureInstance(structure: top)]), "Instances must reference bottom-level structures")
            let bottomInstance = AccelerationStructureInstance(structure: bottom)
            #expect(!commands.encodeBuild(of: top, instances: [bottomInstance, bottomInstance]), "More instances than the capacity")
            await context.queue.drain()
        }
    }
#endif
