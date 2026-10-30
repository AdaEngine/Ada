#if os(macOS) || os(Windows) || os(Linux)
import AdaAssets
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
    @Suite("World distance fields", .enabled(if: GoldenFrame.isEnabled))
    @MainActor
    struct DistanceFields {
        private static func texture(counts: [Int], columns: Int = 1, value: (Vector3) -> Float) -> Texture2D {
            let width = counts[0] * columns
            let height = counts[1] * ((counts[2] + columns - 1) / columns)
            var values = [Float](repeating: 1000, count: width * height)
            for z in 0..<counts[2] { for y in 0..<counts[1] { for x in 0..<counts[0] {
                let row = (z / columns) * counts[1] + y
                let column = (z % columns) * counts[0] + x
                values[row * width + column] = value([Float(x), Float(y), Float(z)])
            } } }
            let texture = Texture2D(descriptor: .init(width: width, height: height, pixelFormat: .r32f,
                textureUsage: [.read], textureType: .texture2D,
                samplerDescription: .init(minFilter: .nearest, magFilter: .nearest, mipFilter: .notMipmapped)))
            unsafe values.withUnsafeBytes { bytes in
                if let base = bytes.baseAddress {
                    unsafe texture.replaceRegion(.init(x: 0, y: 0, width: width, height: height),
                        withBytes: base, bytesPerRow: width * MemoryLayout<Float>.stride)
                }
            }
            return texture
        }

        private static func boxDistance(_ point: Vector3, center: Vector3, half: Vector3) -> Float {
            let q = Vector3(abs(point.x-center.x), abs(point.y-center.y), abs(point.z-center.z)) - half
            let outside = Vector3(max(q.x, 0), max(q.y, 0), max(q.z, 0)).length
            return outside + min(max(q.x, max(q.y, q.z)), 0)
        }

        private static func mean(_ image: Image, x: Int = 320, y: Int = 240, radius: Int = 12) -> Float {
            var value: Float = 0
            for row in (y-radius)..<(y+radius) { for column in (x-radius)..<(x+radius) {
                value += image.getPixel(x: column, y: row).red
            } }
            return value / Float(4 * radius * radius)
        }

        @Test
        func anOccluderBehindTheCameraShadowsTheRealReceiverAndRespectsFlags() async throws {
            let scene = try await DebugViews.makeScene()
            for entity in scene.app.main.getEntities() where entity.id != scene.camera.id && entity.id != scene.sun.id {
                scene.app.main.removeEntity(entity)
            }
            scene.camera.components[Transform.self] = Transform()
            scene.sun.components[Transform.self] = Transform()
            scene.sun.components[DirectionalLightComponent.self] = .init(radiance: .one, intensity: 2, castShadows: true)
            try scene.configure {
                $0.imageBasedLighting = nil
                $0.skybox.isEnabled = false
                $0.shadows.isEnabled = false
                $0.localShadows.isEnabled = false
                $0.screenSpaceReflection.isEnabled = false
                $0.screenSpaceGI.isEnabled = false
                $0.ambientOcclusion.isEnabled = false
                $0.contactShadows.isEnabled = false
                $0.fog.isEnabled = false
                $0.postProcess.autoExposure.isEnabled = false
                $0.postProcess.bloom.isEnabled = false
                $0.postProcess.exposureEV = 0
            }
            let material = PBRMaterial()
            material.baseColorFactor = [0.8, 0.8, 0.8, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 1
            let receiver = scene.app.main.spawn("SDF shadow receiver") {
                Mesh3DComponent(mesh: Mesh.generateCube(size: [8, 6, 0.1], renderDevice: scene.device), materials: [material])
                Transform(position: [0, 0, 2.05])
            }
            // The entire occluder is behind the camera. It has no draw entity
            // and conventional/contact shadows are disabled, so only the world
            // distance field can produce this shadow on the visible receiver.
            let minimum = Vector3(-4, -3, -3)
            let counts = [33, 25, 29]
            let map = Self.texture(counts: counts, columns: 3) { node in
                Self.boxDistance(minimum + node * 0.25, center: [0, 0, -1.5], half: [0.5, 0.5, 0.25])
            }
            let field = try DistanceField3D(minimum: minimum, voxelSize: 0.25, counts: counts, texture: map, atlasColumns: 3)
            let baseline = try await scene.render(.none)
            let control = Self.mean(baseline)
            try #require(control > 0.15, "The receiver must actually be lit before SDF is enabled.")
            try scene.configure {
                $0.distanceField = .init(asset: AssetHandle(field), maxDistance: 6, maxSteps: 48, surfaceBias: 0.08, softness: 0)
            }
            let shadowed = try await scene.render(.none)
            let dark = Self.mean(shadowed)
            #expect(dark < control * 0.65, "An off-camera world occluder must attenuate real direct lighting.")
            #expect(Self.mean(shadowed, x: 510) > Self.mean(baseline, x: 510) * 0.95,
                "A clear ray must retain its light instead of darkening the whole receiver.")

            var mesh = try #require(receiver.components[Mesh3DComponent.self])
            mesh.receiveShadows = false
            receiver.components[Mesh3DComponent.self] = mesh
            let noReceive = try await scene.render(.none)
            #expect(abs(Self.mean(noReceive)-control) < 0.01, "receiveShadows=false must bypass SDF shadows.")
            mesh.receiveShadows = true
            receiver.components[Mesh3DComponent.self] = mesh
            scene.sun.components[DirectionalLightComponent.self] = .init(radiance: .one, intensity: 2, castShadows: false)
            let noCast = try await scene.render(.none)
            #expect(abs(Self.mean(noCast)-control) < 0.01, "A light which does not cast shadows must bypass SDF.")
            scene.sun.components[DirectionalLightComponent.self] = .init(radiance: .one, intensity: 2, castShadows: true)

            // Translate all world geometry and the field together. The projected
            // receiver is identical; screen-space or stale-view queries fail here.
            let offset = Vector3(19, -7, 11)
            scene.camera.components[Transform.self] = Transform(position: offset)
            receiver.components[Transform.self] = Transform(position: offset + Vector3(0, 0, 2.05))
            let translatedField = try DistanceField3D(minimum: minimum + offset, voxelSize: 0.25,
                counts: counts, texture: map, atlasColumns: 3)
            try scene.configure {
                $0.distanceField = .init(asset: AssetHandle(translatedField), maxDistance: 6, maxSteps: 48, surfaceBias: 0.08, softness: 0)
            }
            let translated = try await scene.render(.none)
            #expect(abs(Self.mean(translated)-dark) < 0.01, "World translation must preserve the shadow.")
            scene.camera.components[Transform.self] = Transform(rotation: Quat(axis: [0, 0, 1], angle: 0.35), position: offset)
            let rolled = try await scene.render(.none)
            #expect(abs(Self.mean(rolled)-dark) < 0.01, "Rotating the camera cannot rotate world-space visibility.")
            scene.camera.components[Transform.self] = Transform(position: offset)
            try scene.configure { $0.distanceField = nil }
            let disabled = try await scene.render(.none)
            #expect(GoldenFrame.compare(baseline, disabled, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance),
                "Disabling SDF must restore the existing rendering path.")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try baseline.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("sdf-world-control.png"))
            try shadowed.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("sdf-world-off-camera-shadow.png"))
            try disabled.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("sdf-world-disabled.png"))
            try JSONEncoder().encode(["control": control, "shadow": dark, "translated": Self.mean(translated), "rolled": Self.mean(rolled)])
                .write(to: GoldenFrame.outputDirectory.appendingPathComponent("sdf-world-shadow.json"))
        }

        @Test
        func tiledAtlasInterpolationPreservesSignedValuesAcrossSliceBoundaries() async throws {
            let scene = try await DebugViews.makeScene()
            let counts = [5, 4, 7]
            let minimum = Vector3(-1, 2, -3)
            func value(_ node: Vector3) -> Float { node.x * 0.1 + node.y * 0.2 + node.z * 0.3 - 1.4 }
            let stacked = Self.texture(counts: counts, value: value)
            let tiled = Self.texture(counts: counts, columns: 3, value: value)
            let query = """
            float z = (floor(gl_FragCoord.x) + 0.5) * 6.0 / 64.0;
            vec3 node = vec3(0.25, 1.5, z);
            if (gl_FragCoord.y > 1.0 && gl_FragCoord.y < 2.0) { node = vec3(3.99, 2.99, z); }
            if (gl_FragCoord.y > 2.0 && gl_FragCoord.y < 3.0) { node = mod(floor(gl_FragCoord.x), 2.0) < 0.5 ? vec3(0.0) : vec3(4.0,3.0,6.0); }
            if (gl_FragCoord.y > 3.0) { node = vec3(z * 0.6, z * 0.4, z); }
            float distance = adaDistanceFieldSample(u_SDFMinimumVoxel.xyz + node * u_SDFMinimumVoxel.w);
            o_Color = vec4(vec3(0.5 + distance * 0.2),1.0);
            """
            let a = try await renderQuery(device: scene.device, texture: stacked, minimum: minimum, voxelSize: 0.5,
                counts: counts, width: 64, height: 4, query: query)
            let b = try await renderQuery(device: scene.device, texture: tiled, minimum: minimum, voxelSize: 0.5,
                counts: counts, width: 64, height: 4, query: query)
            var maximumError: Float = 0
            for y in 0..<4 { for x in 0..<64 {
                let z = (Float(x)+0.5) * 6 / 64
                var node = Vector3(0.25, 1.5, z)
                if y == 1 { node = [3.99, 2.99, z] }
                if y == 2 { node = x % 2 == 0 ? .zero : [4, 3, 6] }
                if y == 3 { node = [z*0.6, z*0.4, z] }
                let reference = 0.5 + value(node) * 0.2
                maximumError = max(maximumError, abs(b.getPixel(x: x, y: y).red-reference))
                #expect(abs(a.getPixel(x: x, y: y).red-b.getPixel(x: x, y: y).red) <= 1.01/255,
                    "Tiling must not blend a neighboring slice or its padded cells.")
            } }
            #expect(maximumError <= 1.01/255, "Trilinear interpolation must preserve both signs and a linear field: \(maximumError).")
        }

        @Test
        func sphereTracingHandlesEntryInsideClearRaysAndConservativeExhaustion() async throws {
            let scene = try await DebugViews.makeScene()
            let minimum = Vector3(-2, -2, -2)
            let counts = [33, 33, 65]
            let map = Self.texture(counts: counts, columns: 5) { node in
                Self.boxDistance(minimum + node * 0.125, center: [0, 0, 2], half: [0.3, 0.3, 0.3])
            }
            let query = """
            int test = int(gl_FragCoord.x);
            vec3 origin = vec3(0.0,0.0,-1.0);
            if (test == 1 || test == 5) { origin.x = 1.25; }
            if (test == 2) { origin.z = -3.0; }
            if (test == 3) { origin.x = 4.0; }
            if (test == 4) { origin.z = 2.0; }
            float visible = adaDistanceFieldVisibility(origin,vec3(0.0,1.0,0.0),vec3(0.0,0.0,1.0),6.0);
            o_Color = vec4(vec3(visible),1.0);
            """
            let full = try await renderQuery(device: scene.device, texture: map, minimum: minimum, voxelSize: 0.125,
                counts: counts, width: 6, height: 1, query: query)
            #expect(full.getPixel(x: 0, y: 0).red < 0.05, "A real box crossing must occlude.")
            #expect(full.getPixel(x: 1, y: 0).red > 0.95, "A clear side ray must remain lit.")
            #expect(full.getPixel(x: 2, y: 0).red < 0.05, "A ray starting outside must enter the volume and find its blocker.")
            #expect(full.getPixel(x: 3, y: 0).red > 0.95, "A ray missing the field extent cannot sample a clamped boundary as a blocker.")
            #expect(full.getPixel(x: 4, y: 0).red < 0.05, "A negative starting distance is already inside an occluder.")
            let limited = try await renderQuery(device: scene.device, texture: map, minimum: minimum, voxelSize: 0.125,
                counts: counts, width: 6, height: 1, steps: 1, query: query)
            #expect(limited.getPixel(x: 1, y: 0).red < 0.05,
                "Exhausting a ray budget before proving it clear must not leak light.")

            // A two-sided 15 cm shell represents an open mesh surface. The ray
            // starts on its geometric plane and points outward. Bias must clear
            // both the shell and conservative interpolation margin, rather than
            // reporting that the receiving surface shadows itself.
            let shellMinimum = Vector3(-0.2, -0.2, -0.2)
            let shellCounts = [5, 13, 5]
            let shell = Self.texture(counts: shellCounts) { node in
                abs(shellMinimum.y + node.y * 0.1) - 0.075
            }
            let shellQuery = """
            float visible = adaDistanceFieldVisibility(vec3(0.0),vec3(0.0,1.0,0.0),vec3(0.0,1.0,0.0),0.8);
            o_Color = vec4(vec3(visible),1.0);
            """
            let insufficientBias = try await renderQuery(device: scene.device, texture: shell, minimum: shellMinimum, voxelSize: 0.1,
                counts: shellCounts, width: 1, height: 1, bias: 0.12, query: shellQuery)
            let clearedShell = try await renderQuery(device: scene.device, texture: shell, minimum: shellMinimum, voxelSize: 0.1,
                counts: shellCounts, width: 1, height: 1, bias: 0.20, query: shellQuery)
            #expect(insufficientBias.getPixel(x: 0, y: 0).red < 0.05,
                "The shell fixture must expose self-shadowing when the origin remains inside the conservative surface margin.")
            #expect(clearedShell.getPixel(x: 0, y: 0).red > 0.95,
                "An outward ray biased beyond the authored shell must retain sunlight.")
        }

        @Test
        func legacyEnvironmentAndMalformedFieldsHaveDefinedBehavior() async throws {
            let scene = try await DebugViews.makeScene()
            #expect(try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8)).distanceField == nil)
            let valid = Self.texture(counts: [2, 2, 2]) { _ in 1 }
            #expect(throws: (any Error).self) { _ = try DistanceField3D(minimum: .zero, voxelSize: 0, counts: [2, 2, 2], texture: valid) }
            #expect(throws: (any Error).self) { _ = try DistanceField3D(minimum: [.nan, 0, 0], voxelSize: 1, counts: [2, 2, 2], texture: valid) }
            #expect(throws: (any Error).self) { _ = try DistanceField3D(minimum: .zero, voxelSize: 1, counts: [2, 0, 2], texture: valid) }
            #expect(throws: (any Error).self) { _ = try DistanceField3D(minimum: .zero, voxelSize: 1, counts: [2, 2, 3], texture: valid) }
            #expect(throws: (any Error).self) { _ = try DistanceField3D(minimum: .zero, voxelSize: 1, counts: [4096, 4096, 4096], texture: valid) }
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaSDF-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var manifest: [String: Any] = ["version": 1, "encoding": "signed-distance-r32f-slices-v1",
                "minimum": ["x": 0, "y": 0, "z": 0], "voxelSize": 1, "counts": [2, 2, 2], "data": "Field.r32f"]
            func load(_ name: String) throws -> DistanceField3D {
                let path = directory.appendingPathComponent(name + ".sdf3d")
                try JSONSerialization.data(withJSONObject: manifest).write(to: path)
                return try #require(try AssetsManager.loadSync(DistanceField3D.self, at: path.path).asset)
            }
            try Data(repeating: 0, count: 4).write(to: directory.appendingPathComponent("Field.r32f"))
            #expect(throws: (any Error).self) { _ = try load("Truncated") }
            var nonfinite = [Float](repeating: 1, count: 8)
            nonfinite[3] = .nan
            try unsafe nonfinite.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("Field.r32f")) }
            #expect(throws: (any Error).self) { _ = try load("Nonfinite") }
            manifest["data"] = "../Field.r32f"
            #expect(throws: (any Error).self) { _ = try load("Traversal") }
            manifest["data"] = "Field.r32f"
            manifest["counts"] = [Int.max, 2, 2]
            #expect(throws: (any Error).self) { _ = try load("Overflow") }
            manifest["counts"] = [2, 2, 2]
            let signed: [Float] = [-1, -0.5, 0, 0.5, 1, 1.5, 2, 2.5]
            try unsafe signed.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("Field.r32f")) }
            let loaded = try load("ValidSigned")
            #expect(loaded.minimum == .zero && loaded.voxelSize == 1 && loaded.counts == [2, 2, 2],
                "A valid signed field must remain loadable after malformed inputs are rejected.")
            _ = scene
        }

        private func renderQuery(device: RenderDevice, texture: Texture2D, minimum: Vector3, voxelSize: Float,
            counts: [Int], width: Int, height: Int, steps: Float = 48, bias: Float = 0.06, query: String) async throws -> Image {
            let source = try ShaderSource(source: """
            #version 450 core
            #pragma stage : vert
            [[main]]
            void sdf_test_vertex() {
                vec2 p[3] = vec2[](vec2(-1,-1),vec2(3,-1),vec2(-1,3));
                gl_Position = vec4(p[gl_VertexIndex],0,1);
            }
            #version 450 core
            #pragma stage : frag
            layout(location=0) out vec4 o_Color;
            layout(binding=11) uniform sampler u_DirectionalShadowSampler;
            #include <AdaEngine/DistanceField3D.glsl>
            [[main]]
            void sdf_test_fragment() {
                \(query)
            }
            """)
            let module = try ShaderCompiler(shaderSource: source).compileShaderModule()
            let pipeline = device.createRenderPipeline(from: .init(vertex: try #require(module.getShader(for: .vertex)),
                fragment: module.getShader(for: .fragment), debugName: "Production SDF query regression",
                backfaceCulling: false, depthPixelFormat: .none, colorAttachments: [.init(format: .bgra8)]))
            let uniform = device.createUniformBuffer(Vector4.self, count: 3, binding: 50)
            var constants: [Vector4] = [Vector4(minimum, voxelSize),
                [Float(counts[0]), Float(counts[1]), Float(counts[2]), 6], [steps, bias, 0, 1]]
            uniform.setElements(&constants)
            let sampler = device.createSampler(from: .init(minFilter: .nearest, magFilter: .nearest))
            let target = RenderTexture(size: [width, height], scaleFactor: 1, format: .bgra8)
            let command = device.createCommandQueue().makeCommandBuffer()
            let pass = command.beginRenderPass(.init(colorAttachments: [
                .init(texture: target, operation: .init(loadAction: .clear, storeAction: .store), clearColor: .red)
            ]))
            pass.setViewport(.init(x: 0, y: 0, width: Float(width), height: Float(height)))
            pass.setRenderPipelineState(pipeline)
            pass.setFragmentBuffer(uniform, offset: 0, slot: 50)
            pass.setFragmentTexture(texture, slot: 49)
            pass.setFragmentSamplerState(sampler, slot: 11)
            pass.draw(type: .triangle, vertexStart: 0, vertexCount: 3, instanceCount: 1)
            pass.endRenderPass()
            command.commit()
            return try #require(try await device.readImage(from: target))
        }
    }
}
#endif
