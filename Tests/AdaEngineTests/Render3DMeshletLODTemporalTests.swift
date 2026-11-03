#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

extension Render3DGPUTests {
    @MainActor
    @Suite("Hierarchical meshlet temporal guides", .enabled(if: GoldenFrame.isEnabled))
    struct MeshletLODTemporal {
        private static func curvedMesh(device: RenderDevice) throws -> Mesh {
            var positions: [Vector3] = []
            for row in 0..<3 {
                for column in 0..<3 {
                    positions.append([Float(column * 2 - 2), Float(row * 2 - 2), row == 1 && column == 1 ? 1 : 0])
                }
            }
            var source: [UInt32] = []
            for column in 0..<2 {
                for row in 0..<2 {
                    let a = UInt32(row * 3 + column), b = a + 3
                    source.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
                }
            }
            let base = try MeshletGeometry.scan(positions: positions, indices: source, maximumTriangles: 2)
            let combined = source + [0, 6, 2, 2, 6, 8]
            let geometry = try MeshletGeometry.scan(positions: positions, indices: combined, maximumTriangles: 2)
            let nodes: [MeshletLODNode] = [
                .init(parent: 2, firstChild: 0, childCount: 0, firstCluster: 0, clusterCount: 2,
                    minimum: [-2, -2, 0], maximum: [0, 2, 1], error: 0, firstSourceIndex: 0, sourceIndexCount: 12),
                .init(parent: 2, firstChild: 0, childCount: 0, firstCluster: 2, clusterCount: 2,
                    minimum: [0, -2, 0], maximum: [2, 2, 1], error: 0, firstSourceIndex: 12, sourceIndexCount: 12),
                .init(parent: nil, firstChild: 0, childCount: 2, firstCluster: 4, clusterCount: 1,
                    minimum: [-2, -2, 0], maximum: [2, 2, 1], error: 1.25, firstSourceIndex: 0, sourceIndexCount: 24, level: 1),
            ]
            let hierarchy = try MeshletLODGeometry(positions: positions, sourceIndices: source, geometry: geometry, nodes: nodes, roots: [2])
            var descriptor = MeshDescriptor(name: "Curved source and flat LOD parent")
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, -1), count: positions.count))
            descriptor.indicies = source
            descriptor.meshlets = base
            descriptor.meshletLOD = hierarchy
            return Mesh.generate(from: [descriptor], renderDevice: device)
        }

        private static func complete(_ command: CommandBuffer) async {
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
            }
        }

        /// RGBA16F image readback is not supported on every backend. Sampling the actual motion
        /// target into UNORM keeps this check on GPU and preserves signed motion around red=.5.
        private static func motionImage(_ texture: RenderTexture, device: RenderDevice) async throws -> Image {
            let source = try ShaderSource(source: """
            #version 450 core
            #pragma stage : vert
            layout(location=0) out vec2 v_UV;
            [[main]]
            void guide_capture_vertex() {
                vec2 uv=vec2(float(gl_VertexIndex >> 1u),float(gl_VertexIndex & 1u))*2.0;
                gl_Position=vec4(uv*vec2(2.0,-2.0)+vec2(-1.0,1.0),0,1); v_UV=uv;
            }
            #version 450 core
            #pragma stage : frag
            layout(location=0) in vec2 v_UV;
            layout(location=0) out vec4 o_Color;
            layout(binding=0) uniform texture2D u_Motion;
            layout(binding=1) uniform sampler u_Nearest;
            [[main]]
            void guide_capture_fragment() {
                vec4 value=textureLod(sampler2D(u_Motion,u_Nearest),v_UV,0.0);
                o_Color=vec4(clamp(vec2(0.5)+value.xy*4.0,vec2(0),vec2(1)),clamp((1.0-value.z)*16.0,0.0,1.0),value.w);
            }
            """)
            let module = try ShaderCompiler(shaderSource: source).compileShaderModule()
            let vertex = try #require(module.getShader(for: .vertex))
            let fragment = try #require(module.getShader(for: .fragment))
            var descriptor = RenderPipelineDescriptor(vertex: vertex, fragment: fragment,
                debugName: "Actual LOD temporal guide readback", backfaceCulling: false, depthPixelFormat: .none)
            descriptor.colorAttachments = [.init(format: .rgba8)]
            let pipeline = device.createRenderPipeline(from: descriptor)
            let output = RenderTexture(size: texture.size, scaleFactor: 1, format: .rgba8)
            let sampler = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped))
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(label: "Sample real motion/depth guides",
                colorAttachments: [.init(texture: output, operation: .init(loadAction: .clear, storeAction: .store))]))
            pass.setViewport(Rect(x: 0, y: 0, width: Float(texture.size.width), height: Float(texture.size.height)))
            pass.setRenderPipelineState(pipeline)
            pass.setResourceSet(.init(bindings: [
                .init(binding: 0, shaderStages: .fragment, resource: .texture(texture)),
                .init(binding: 1, shaderStages: .fragment, resource: .sampler(sampler)),
            ]), index: 0)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            await Self.complete(command)
            return try #require(try await device.readImage(from: output))
        }

        private static func firstWord(_ buffer: Buffer) async throws -> UInt32 {
            let bytes = try await buffer.readData()
            try #require(bytes.count >= 4)
            let a = UInt32(bytes[0]), b = UInt32(bytes[1]) << 8
            let c = UInt32(bytes[2]) << 16, d = UInt32(bytes[3]) << 24
            return a | b | c | d
        }

        @Test
        func movingCurvedSourceUsesItsActualCoarseSurfaceForTemporalGuides() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [320, 240], cameraPosition: [0, 0, -6])
            var camera = try #require(scene.camera.components[Camera.self])
            camera.projection = .perspective(.init(near: 0.1, far: 100, fieldOfView: .degrees(60), aspectRation: 4.0 / 3.0))
            camera.temporalUpscaling = .init(renderScale: 0.5, method: .portable)
            scene.camera.components[Camera.self] = camera
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.meshVisibility.meshlets = .gpu
            environment.meshVisibility.meshletLODPixelError = 128
            environment.gpuOcclusionEnabled = false
            environment.postProcess.autoExposure.isEnabled = false
            environment.postProcess.bloom.isEnabled = false
            scene.camera.components[Environment3D.self] = environment
            let mesh = try Self.curvedMesh(device: scene.device)
            let material = PBRMaterial()
            material.baseColorFactor = [0.7, 0.35, 0.12, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 1
            let object = scene.app.main.spawn("Moving curved-source LOD object") {
                Mesh3DComponent(mesh: mesh, materials: [material])
                Transform()
            }
            for _ in 0..<6 { try await scene.app.update() }
            let render = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let statistics = try #require(render.getResource(Render3DMeshletStatistics.self))
            let before = try #require(statistics.snapshots[String(scene.camera.id)])
            #expect(before.motionLODItems == 1 && before.motionLODTriangles == 2)
            object.components[Transform.self] = Transform(position: [-0.4, 0, 0])
            // Read the first moved frame: another app update would correctly replace its velocity with zero.
            try await scene.app.update()
            let count = try #require(statistics.snapshots[String(scene.camera.id)])
            #expect(count.lodGPUItems == 1 && count.motionLODItems == 1 && count.motionLODTriangles == 2)
            let state = try #require(render.getResource(Meshlet3DState.self))
            let gpuOutput = try #require(state.output(for: scene.camera.id))
            #expect(try await Self.firstWord(gpuOutput.arguments) == 6)
            let targets = try #require(render.getResource(ExtractedCameraRenderViewTargets.self)?.targets[scene.camera.id])
            #expect(targets.temporalUpscalingActive && !targets.temporalReset)
            let motion = try #require(targets.temporalMotionTexture)
            #expect(motion.size == SizeInt(width: 160, height: 120))
            let sampled = try await Self.motionImage(motion, device: scene.device)
            var movingSurfacePixels = 0
            for y in (sampled.height / 2 - 6)..<(sampled.height / 2 + 6) {
                for x in (sampled.width / 2 - 6)..<(sampled.width / 2 + 6) {
                    let color = sampled.getPixel(x: x, y: y)
                    if color.red > 0.6 && color.blue > 0.15 && abs(color.green - 0.5) < 0.03 { movingSurfacePixels += 1 }
                }
            }
            #expect(movingSurfacePixels > 120,
                "Original curved geometry sits behind the coarse depth and leaves sky guides; real coarse guides must encode prior object motion over the center patch.")
            let temporal = try #require(render.getResource(Render3DTemporalStatistics.self)?.snapshots[String(scene.camera.id)])
            #expect(temporal.encodedFrames >= 6 && temporal.fallbackFrames == 0)

            var items = try #require(render.getResource(VisibleMesh3DLists.self)).items(view: scene.camera.id, pass: -1)
            var guides = state
            let uniform = try #require(scene.camera.components[GlobalViewUniform.self])
            let prepared = guides.prepareMotion(items: &items, view: scene.camera.id, settings: environment.meshVisibility, projection: uniform.viewProjectionMatrix,
                viewport: [320, 240], device: scene.device)
            #expect(prepared.items == 1 && prepared.triangles == 2)
            let override = try #require(items.first?.meshletOverride)
            #expect(override.arguments == nil && override.ranges == [24..<30])
            #expect(override.indices !== gpuOutput.indices, "Motion guides cannot borrow a compacted output whose GPU frame lease already completed.")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try sampled.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("meshlet-lod-temporal-guides.png"))
        }
    }
}
#endif
