#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
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

@Suite("Meshlet rendering settings")
struct Render3DMeshletSettingsTests {
    @Test func legacyScenesOptOutAndExplicitModesRoundTrip() throws {
        let legacy = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(legacy.meshVisibility.meshlets == .disabled)
        for mode: MeshletVisibilityMode3D in [.disabled, .cpuReference, .gpu] {
            var environment = Environment3D()
            environment.meshVisibility.meshlets = mode
            environment.debugView = .meshlets
            let restored = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
            #expect(restored.meshVisibility.meshlets == mode && restored.debugView == .meshlets)
        }
    }

    @Test func explicitStorageAndIndirectLayoutsMatchShaderContracts() {
        #expect(MemoryLayout<MeshletGPUDescriptor>.stride == 64)
        #expect(MemoryLayout<MeshletGPUDescriptor>.offset(of: \.range) == 0)
        #expect(MemoryLayout<MeshletGPUDescriptor>.offset(of: \.minimum) == 16)
        #expect(MemoryLayout<MeshletGPUDescriptor>.offset(of: \.maximum) == 32)
        #expect(MemoryLayout<MeshletGPUDescriptor>.offset(of: \.reserved) == 48)
        #expect(MemoryLayout<MeshletGPUView>.stride == 224)
        #expect(MemoryLayout<MeshletGPUView>.offset(of: \.projection) == 0)
        #expect(MemoryLayout<MeshletGPUView>.offset(of: \.transform) == 64)
        #expect(MemoryLayout<MeshletGPUView>.offset(of: \.parameters) == 128)
        #expect(MemoryLayout<MeshletGPUView>.offset(of: \.lodProjection) == 144)
        #expect(MemoryLayout<MeshletGPUView>.offset(of: \.lod) == 208)
        #expect(MemoryLayout<IndexedIndirectArguments>.stride == 20)
        #expect(MemoryLayout<IndexedIndirectArguments>.offset(of: \.firstInstance) == 16)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["ADAENGINE_VALIDATE_TINT"] == "1"), arguments: [0, 1, 2, 3])
    func mapShadersCompileFreshForEveryAttachmentLayout(variant: Int) async throws {
        let root = ProcessInfo.processInfo.environment["ADAENGINE_SHADER_SOURCE_ROOT"].map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let compiler = try ShaderCompiler(from: root.appendingPathComponent("Sources/AdaCorePipelines/Assets/Shaders/meshlet_map_3d.glsl"))
        if variant & 1 != 0 { compiler.setMacro("MAP_RESPONSE", value: "1", for: .fragment) }
        if variant & 2 != 0 { compiler.setMacro("MAP_SURFACE", value: "1", for: .fragment) }
        for stage in [ShaderStage.vertex, .fragment] {
            let binary = try compiler.compileSpirvBin(for: stage, ignoreCache: true)
            let converted = try await WGSLShaderCompiler().compile(
                spirvData: binary.data, entryPoint: "meshlet_map_validation", stage: stage, defines: []
            )
            #expect(converted.language == .wgsl && converted.source.contains("fn meshlet_map_validation("))
        }
    }
}

extension Render3DGPUTests {
    @MainActor
    @Suite("Meshlet rendering", .enabled(if: GoldenFrame.isEnabled))
    struct Meshlets {
        private static func material() -> PBRMaterial {
            let material = PBRMaterial()
            material.baseColorFactor = [0.8, 0.3, 0.12, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 0.8
            return material
        }

        /// Consecutive columns create tight local scan clusters instead of clusters spanning the whole mesh.
        private static func panel(device: RenderDevice) throws -> Mesh {
            var descriptor = MeshDescriptor(name: "Meshlet correctness panel")
            var positions: [Vector3] = [], normals: [Vector3] = [], indices: [UInt32] = []
            for column in 0..<96 {
                for row in 0..<4 {
                    let x = Float(column) * 0.3125 - 6, y = Float(row) - 2
                    let first = UInt32(positions.count)
                    positions += [[x, y, 0], [x + 0.3125, y, 0], [x, y + 1, 0], [x + 0.3125, y + 1, 0]]
                    normals += Array(repeating: [0, 0, -1], count: 4)
                    indices += [first, first + 2, first + 1, first + 1, first + 2, first + 3]
                }
            }
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(normals)
            descriptor.indicies = indices
            descriptor.meshlets = try MeshletGeometry.scan(positions: positions, indices: indices)
            return Mesh.generate(from: [descriptor], renderDevice: device)
        }

        private static func frame(
            _ scene: MeshletBaselineFixtures.Scene, mode: MeshletVisibilityMode3D, debug: DebugView3D = .albedo
        ) async throws -> Image {
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.meshVisibility.meshlets = mode
            environment.gpuOcclusionEnabled = false
            environment.debugView = debug
            environment.postProcess.autoExposure.isEnabled = false
            environment.postProcess.bloom.isEnabled = false
            scene.camera.components[Environment3D.self] = environment
            for _ in 0..<3 { try await scene.app.update() }
            return try #require(try await scene.device.readImage(from: scene.target))
        }

        private static func count(_ scene: MeshletBaselineFixtures.Scene) throws -> Meshlet3DCount {
            let statistics = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DMeshletStatistics.self))
            return try #require(statistics.snapshots[String(scene.camera.id)])
        }

        @Test
        func allVisibleAndPartlyVisibleClustersMatchOriginalPixels() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [480, 320], cameraPosition: [0, 0, -40])
            let mesh = try Self.panel(device: scene.device)
            scene.app.main.spawn("One eligible panel") {
                Mesh3DComponent(mesh: mesh, materials: [Self.material()])
                Transform(position: [0, 0, 6])
            }
            for z: Float in [-40, -6] {
                scene.camera.components[Transform.self] = Transform(position: [0, 0, z])
                let original = try await Self.frame(scene, mode: .disabled)
                let cpu = try await Self.frame(scene, mode: .cpuReference)
                let cpuCount = try Self.count(scene)
                #expect(cpu.data == original.data, "CPU meshlet ranges changed original pixels at camera Z \(z).")
                #expect(cpuCount.eligibleItems == 1 && cpuCount.candidateMeshlets > 2)
                if z == -6 {
                    #expect(cpuCount.cpuVisibleMeshlets > 0 && cpuCount.cpuVisibleMeshlets < cpuCount.candidateMeshlets)
                    #expect(cpuCount.cpuSubmittedTriangles < cpuCount.sourceTriangles)
                } else {
                    #expect(cpuCount.cpuVisibleMeshlets == cpuCount.candidateMeshlets)
                    #expect(cpuCount.cpuSubmittedTriangles == cpuCount.sourceTriangles)
                }
                let gpu = try await Self.frame(scene, mode: .gpu)
                #expect(gpu.data == original.data, "Compacted GPU indices changed original pixels at camera Z \(z).")
                let gpuCount = try Self.count(scene)
                let output = scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Meshlet3DState.self)?.output(for: scene.camera.id)
                if z == -6 {
                    #expect(gpuCount.gpuDraws == 1, "A partially visible eligible item must encode a real compacted draw.")
                    let compacted = try #require(output)
                    #expect(compacted.drawCount == 1)
                    let arguments = try await compacted.arguments.readData()
                    #expect(Self.words(arguments).first == UInt32(cpuCount.cpuSubmittedTriangles * 3))
                } else {
                    #expect(gpuCount.eligibleItems == 1 && gpuCount.fullyVisibleItems == 1)
                    #expect(gpuCount.fastPathTriangles == cpuCount.sourceTriangles && gpuCount.gpuDraws == 0)
                    #expect(output == nil, "All-visible geometry must retain the original draw without copying every index.")
                }
            }
        }

        @Test
        func meshletMapHasStableDistinctColorsAndPreservesCoverage() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [480, 320], cameraPosition: [0, 0, -12])
            scene.camera.components[Camera.self]?.backgroundColor = .black
            let mesh = try Self.panel(device: scene.device)
            scene.app.main.spawn("Map panel") {
                Mesh3DComponent(mesh: mesh, materials: [Self.material()])
                Transform(position: [0, 0, 6])
            }
            let reference = try await Self.frame(scene, mode: .disabled)
            let first = try await Self.frame(scene, mode: .cpuReference, debug: .meshlets)
            let repeated = try await Self.frame(scene, mode: .cpuReference, debug: .meshlets)
            #expect(first.data == repeated.data, "Cluster colors must not flicker between identical frames.")
            var colors = Set<UInt32>(), covered = 0, coverageMismatch = 0
            for y in 0..<reference.height {
                for x in 0..<reference.width {
                    let a = reference.getPixel(x: x, y: y), b = first.getPixel(x: x, y: y)
                    let originalCovered = max(a.red, a.green, a.blue) > 0.05
                    let mapCovered = max(b.red, b.green, b.blue) > 0.05
                    if originalCovered != mapCovered { coverageMismatch += 1 }
                    if originalCovered && mapCovered {
                        covered += 1
                        let key = UInt32(b.red * 255) << 16 | UInt32(b.green * 255) << 8 | UInt32(b.blue * 255)
                        colors.insert(key)
                    }
                }
            }
            #expect(covered > 2000)
            #expect(coverageMismatch < 16, "Debug coloring must preserve the original silhouette, without dropping meshlets.")
            #expect(colors.count > 3, "The map must display several actual cluster IDs, not one color per coarse mesh.")
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try first.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("meshlet-map.png"))
        }

        @Test
        func instancingAndMaskedMaterialsRetainCompleteLegacyGeometry() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [320, 240], cameraPosition: [0, 0, -18])
            let mesh = try Self.panel(device: scene.device), material = Self.material()
            for x: Float in [-1, 1] {
                scene.app.main.spawn("Shared instanced panel") {
                    Mesh3DComponent(mesh: mesh, materials: [material])
                    Transform(position: [x, 0, 6])
                }
            }
            let original = try await Self.frame(scene, mode: .disabled)
            let actual = try await Self.frame(scene, mode: .gpu)
            #expect(actual.data == original.data)
            let render = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let items = try #require(render.getResource(VisibleMesh3DLists.self)).items(view: scene.camera.id, pass: -1)
            #expect(items.count == 1 && items.first?.batchRange?.count == 2, "Meshlets must not split an instanced batch into singleton draws.")
            #expect(try Self.count(scene).gpuDraws == 0)
            #expect(try Self.count(scene).fallbackItems > 0)
            for entity in scene.app.main.getEntities() where entity.components[Mesh3DComponent.self] != nil { scene.app.main.removeEntity(entity.id) }
            let masked = Self.material()
            masked.alphaMode = .mask
            scene.app.main.spawn("Masked panel") {
                Mesh3DComponent(mesh: mesh, materials: [masked])
                Transform(position: [0, 0, 6])
            }
            let maskOriginal = try await Self.frame(scene, mode: .disabled)
            let maskActual = try await Self.frame(scene, mode: .gpu)
            #expect(maskActual.data == maskOriginal.data)
            #expect(try Self.count(scene).gpuDraws == 0 && Self.count(scene).fallbackItems > 0)
        }

        private static func words(_ data: Data) -> [UInt32] {
            let byteCount = data.count - data.count % 4
            return stride(from: 0, to: byteCount, by: 4).map { offset -> UInt32 in
                let byte0 = UInt32(data[offset])
                let byte1 = UInt32(data[offset + 1]) << 8
                let byte2 = UInt32(data[offset + 2]) << 16
                let byte3 = UInt32(data[offset + 3]) << 24
                return byte0 | byte1 | byte2 | byte3
            }
        }

        private static func complete(_ command: any CommandBuffer) async {
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
            }
        }

        @Test
        func gpuCompactionMatchesCPUOrderAcrossWorkgroupsAndSegments() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
            let processor = try #require(scene.device.createMeshletVisibilityProcessor())
            var positions: [Vector3] = [], indices: [UInt32] = []
            for index in 0..<600 {
                let x: Float = index % 3 == 2 ? 2 : (index % 3 == 0 ? -0.5 : 0.5)
                let y = Float(index / 3 % 20) * 0.04 - 0.4
                let first = UInt32(positions.count)
                positions += [[x, y, 0.5], [x + 0.01, y, 0.5], [x, y + 0.01, 0.5]]
                indices += [first, first + 1, first + 2]
            }
            let geometry = try MeshletGeometry.scan(positions: positions, indices: indices, maximumVertices: 3, maximumTriangles: 1)
            var descriptor = MeshDescriptor(name: "Multi-workgroup compaction")
            descriptor.positions = MeshBuffer(positions)
            descriptor.indicies = indices
            let source = descriptor.getIndexBuffer(renderDevice: scene.device)
            let transforms = [Transform3D.identity, Transform3D(translation: [4, 0, 0]), Transform3D(translation: [4, 0, 0])]
            let draws = transforms.enumerated().map { index, transform in
                MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: source, transform: transform, forceVisible: index == 2)
            }
            #expect(MeshletVisibilityPlan(draws: draws, projection: .identity, bufferLimit: 256) == nil)
            var invalidProjection = Transform3D.identity
            invalidProjection.x.x = .nan
            #expect(MeshletVisibilityPlan(draws: draws, projection: invalidProjection) == nil)
            #expect(MeshletVisibilityPlan(draws: [], projection: .identity) == nil)
            let checkedPlan = try #require(MeshletVisibilityPlan(draws: draws, projection: .identity))
            #expect(checkedPlan.firstIndices == [0, 1800, 3600] && checkedPlan.indexCount == 5400 && checkedPlan.argumentBytes == 60)
            let frustum = MeshVisibilityFrustum3D(viewProjection: .identity)
            var expected: [[UInt32]] = []
            for (index, transform) in transforms.enumerated() {
                var visible: [UInt32] = []
                for cluster in geometry.clusters {
                    let local = AABB(min: cluster.minimum, max: cluster.maximum)
                    if index == 2 || frustum.intersects(MeshVisibility3DMath.transformed(local, by: transform)) {
                        visible += indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)]
                    }
                }
                expected.append(visible)
            }
            #expect(expected[0].count == 1200 && expected[1].isEmpty && expected[2].count == 1800)
            for _ in 0..<6 {
                let command = scene.device.createCommandQueue().makeCommandBuffer()
                let output = try #require(processor.encode(on: command, viewProjection: .identity, draws: draws))
                await Self.complete(command)
                let argumentWords = Self.words(try await output.arguments.readData())
                let outputWords = Self.words(try await output.indices.readData())
                #expect(output.drawCount == 3)
                for draw in 0..<3 {
                    let base = draw * 5, first = draw * indices.count
                    #expect(Array(argumentWords[base..<(base + 5)]) == [UInt32(expected[draw].count), 1, UInt32(first), 0, 0])
                    #expect(Array(outputWords[first..<(first + expected[draw].count)]) == expected[draw],
                        "Stable compaction must preserve winding, triangle order and per-draw segment boundaries.")
                }
            }
        }

        @Test
        func affineGPUWorldBoundsMatchCPUAcrossRotatedFrustaAndClipPlanes() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
            let processor = try #require(scene.device.createMeshletVisibilityProcessor())
            let centers: [Vector3] = [
                .zero, [0, 0, -0.7], [0, 0, -0.5], [0, 0, 0.5], [0, 0, 0.7],
                [-2.4, 0, 0], [2.4, 0, 0], [0, -1.4, 0], [0, 1.4, 0], [0.3, 0.2, 0.2],
            ]
            var positions: [Vector3] = [], indices: [UInt32] = []
            for center in centers {
                let first = UInt32(positions.count)
                positions.append(center + Vector3(-1, -0.01, -0.15))
                positions.append(center + Vector3(1, -0.01, 0.15))
                positions.append(center + Vector3(0, 0.01, 0.05))
                indices.append(contentsOf: [first, first + 1, first + 2])
            }
            let geometry = try MeshletGeometry.scan(positions: positions, indices: indices, maximumVertices: 3, maximumTriangles: 1)
            var descriptor = MeshDescriptor(name: "Affine world-AABB oracle")
            descriptor.positions = MeshBuffer(positions)
            descriptor.indicies = indices
            let source = descriptor.getIndexBuffer(renderDevice: scene.device)
            let rotation = Quat(axis: [0, 0, 1], angle: .pi / 4)
            let rotatedFrustum = Transform3D(quat: rotation)
            let looseWorldBounds = Transform3D(translation: [0.848528, -0.848528, 0.5], rotation: rotation, scale: .one)
            var shear = Transform3D.identity
            shear.y.x = 0.8
            shear.z.y = 0.35
            shear.w = [-0.15, 0.25, 0.5, 1]
            let perspective = Transform3D.perspective(fieldOfView: .degrees(70), aspectRatio: 1.2, zNear: 0.4, zFar: 1.1)
            let cases: [(String, Transform3D, Transform3D)] = [
                ("world-aabb-corner", rotatedFrustum, looseWorldBounds),
                ("rotation", rotatedFrustum, .init(translation: [0.2, 0.15, 0.5], rotation: rotation, scale: .one)),
                ("reflection", rotatedFrustum, .init(translation: [0.15, -0.1, 0.5], rotation: rotation, scale: [-1.1, 0.6, 1.4])),
                ("nonuniform", .identity, .init(translation: [0.2, -0.1, 0.5], rotation: rotation, scale: [2, 0.3, 0.8])),
                ("shear", rotatedFrustum, shear),
                ("orthographic-planes", .identity, .init(translation: [0, 0, 0.5])),
                ("perspective-planes", perspective, .init(translation: [0, 0, 0.5])),
            ]
            let queue = scene.device.createCommandQueue()
            for (name, projection, transform) in cases {
                let frustum = MeshVisibilityFrustum3D(viewProjection: projection)
                var expected: [UInt32] = []
                for cluster in geometry.clusters {
                    let local = AABB(min: cluster.minimum, max: cluster.maximum)
                    if frustum.intersects(MeshVisibility3DMath.transformed(local, by: transform)) {
                        expected.append(contentsOf: indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)])
                    }
                }
                if name == "world-aabb-corner" {
                    // An OBB corner test rejects this cluster, but the established CPU world-AABB
                    // contract conservatively retains it. Rotation of both object and frustum is essential.
                    let cluster = try #require(geometry.clusters.first)
                    #expect(expected.starts(with: [0, 1, 2]))
                    for corner in 0..<8 {
                        let p = Vector3(corner & 1 == 0 ? cluster.minimum.x : cluster.maximum.x,
                            corner & 2 == 0 ? cluster.minimum.y : cluster.maximum.y,
                            corner & 4 == 0 ? cluster.minimum.z : cluster.maximum.z)
                        let clip = projection * transform * Vector4(p, 1)
                        #expect(clip.x > clip.w + 0.05, "The fixture must expose the old tighter OBB rejection.")
                    }
                }
                #expect(!expected.isEmpty && expected.count < indices.count, "\(name) must exercise both retained and rejected clusters.")
                let draw = MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: source, transform: transform)
                try #require(MeshletVisibilityPlan(draws: [draw], projection: projection) != nil)
                let command = queue.makeCommandBuffer()
                let output = try #require(processor.encode(on: command, viewProjection: projection, draws: [draw]))
                await Self.complete(command)
                let arguments = Self.words(try await output.arguments.readData())
                let compacted = Self.words(try await output.indices.readData())
                #expect(Array(arguments.prefix(5)) == [UInt32(expected.count), 1, 0, 0, 0], "\(name) GPU visibility differs from CPU world bounds.")
                #expect(Array(compacted.prefix(expected.count)) == expected, "\(name) changed stable triangle order or winding.")
            }
            var projectiveObject = Transform3D.identity
            projectiveObject.x.w = 0.125
            let invalid = MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: source, transform: projectiveObject)
            #expect(MeshletVisibilityPlan(draws: [invalid], projection: perspective) == nil)
            let rejected = queue.makeCommandBuffer()
            #expect(processor.encode(on: rejected, viewProjection: perspective, draws: [invalid]) == nil,
                "A projective object transform must select complete legacy geometry, not use affine-only bounds.")
        }

        @Test
        func occupiedFrameRingFallsBackThenReusesCompletedSlots() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
            let processor = try #require(scene.device.createMeshletVisibilityProcessor())
            let mesh = try Self.panel(device: scene.device)
            let part = try #require(mesh.models.first?.parts.first)
            let geometry = try #require(part.meshlets)
            let draw = MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: part.indexBuffer, transform: .identity, forceVisible: true)
            let queue = scene.device.createCommandQueue()
            var commands: [any CommandBuffer] = []
            let flightCount = max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
            for _ in 0..<flightCount {
                let command = queue.makeCommandBuffer()
                try #require(processor.encode(on: command, viewProjection: .identity, draws: [draw]) != nil)
                commands.append(command)
            }
            let blocked = queue.makeCommandBuffer()
            #expect(processor.encode(on: blocked, viewProjection: .identity, draws: [draw]) == nil,
                "In-flight output buffers must never be overwritten to avoid a legacy fallback.")
            for command in commands { await Self.complete(command) }
            let reused = queue.makeCommandBuffer()
            let output = try #require(processor.encode(on: reused, viewProjection: .identity, draws: [draw]))
            await Self.complete(reused)
            #expect(Self.words(try await output.arguments.readData()).first == UInt32(part.indexCount))
        }

        @Test
        func modelImportAttachesMatchingSidecarAndRetainsSourceWhenStaleOrCorrupt() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ada-meshlet-test-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let positions: [Vector3] = [[-1, -1, 0], [1, -1, 0], [-1, 1, 0], [1, 1, 0]]
            let indices: [UInt32] = [0, 2, 1, 1, 2, 3]
            var binary = Data()
            func word(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { binary.append(UInt8((value >> shift) & 255)) } }
            for position in positions { word(position.x.bitPattern); word(position.y.bitPattern); word(position.z.bitPattern) }
            for index in indices { word(index) }
            try binary.write(to: directory.appendingPathComponent("geometry.bin"))
            let object: [String: Any] = [
                "asset": ["version": "2.0"], "scene": 0,
                "scenes": [["nodes": [0]]], "nodes": [["mesh": 0]],
                "buffers": [["uri": "geometry.bin", "byteLength": 72]],
                "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": 48], ["buffer": 0, "byteOffset": 48, "byteLength": 24]],
                "accessors": [["bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"],
                              ["bufferView": 1, "componentType": 5125, "count": 6, "type": "SCALAR"]],
                "materials": [["pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1]]],
                "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]]]],
            ]
            let source = try JSONSerialization.data(withJSONObject: object)
            let geometry = try MeshletGeometry.scan(positions: positions, indices: indices)
            let valid = try MeshletSidecar(parts: [.init(meshIndex: 0, partIndex: 0, geometry: geometry)]).encoded()
            let moved = positions.map { $0 + Vector3(0.25, 0, 0) }
            let staleGeometry = try MeshletGeometry.scan(positions: moved, indices: indices)
            let stale = try MeshletSidecar(parts: [.init(meshIndex: 0, partIndex: 0, geometry: staleGeometry)]).encoded()
            let cases: [(String, Data?)] = [("missing", nil), ("valid", valid), ("stale", stale), ("corrupt", Data([1, 2, 3]))]
            for (name, sidecar) in cases {
                let file = directory.appendingPathComponent(name + ".gltf")
                try source.write(to: file)
                if let sidecar { try sidecar.write(to: file.appendingPathExtension("meshlets")) }
                // Unique source names deliberately bypass AssetManager's loaded-object cache.
                let model = try #require(try await AssetsManager.load(ModelAsset3D.self, at: file.path).asset)
                let part = try #require(model.meshes.first?.models.first?.parts.first)
                #expect(part.indexCount == indices.count && part.meshDescriptor.indicies == indices)
                #expect(part.meshDescriptor.positions.elements == positions)
                #expect((part.meshlets != nil) == (name == "valid"), "Only matching normalized geometry may attach derived meshlets.")
                if name == "valid" {
                    var changed = part
                    changed.indexBuffer = part.meshDescriptor.getIndexBuffer(renderDevice: scene.device)
                    #expect(changed.meshlets == nil, "Replacing the index generation must invalidate prepared clustering.")
                    changed = part
                    changed.vertexBuffer = part.meshDescriptor.getVertexBuffer(renderDevice: scene.device)
                    #expect(changed.meshlets == nil, "Replacing the vertex generation must invalidate cluster bounds.")
                    changed = part
                    changed.indexCount -= 3
                    #expect(changed.meshlets == nil, "A modified source count must retain the ordinary renderer.")
                }
                if name == "stale" || name == "corrupt" {
                    #expect(model.importWarnings.contains { $0.contains("meshlet") })
                }
            }
        }
    }
}

extension Render3DGPUTests.Meshlets {
    /// Delegation does not prove a custom pass consumes geometry overrides or preserves vertex coverage.
    private struct UnmarkedModelPass: DrawPass {
        private let base = Model3DDrawPass()

        init() {}

        func render(with encoder: RenderCommandEncoder, world: World, view: Entity, item: Opaque3DRenderItem) throws {
            try base.render(with: encoder, world: world, view: view, item: item)
        }
    }

    @Test
    func anUnknownDrawPassRetainsOriginalPreparedGeometry() async throws {
        let scene = try await MeshletBaselineFixtures.empty(size: [160, 120], cameraPosition: [0, 0, -6])
        let mesh = try Self.panel(device: scene.device)
        scene.app.main.spawn("Prepared custom-pass source") {
            Mesh3DComponent(mesh: mesh, materials: [Self.material()])
            Transform(position: [0, 0, 6])
        }
        _ = try await Self.frame(scene, mode: .disabled)
        let render = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
        let lists = try #require(render.getResource(VisibleMesh3DLists.self))
        let original = try #require(lists.items(view: scene.camera.id, pass: -1).first)
        #expect(Meshlet3DEligibility.fallbackReason(original) == nil, "The actual extracted singleton must otherwise be eligible.")
        let custom = Opaque3DRenderItem(entity: original.entity, drawPass: UnmarkedModelPass(), sortKey: original.sortKey,
            modelIndex: original.modelIndex, partIndex: original.partIndex, mesh: original.mesh, material: original.material,
            worldTransform: original.worldTransform, castShadows: original.castShadows, receiveShadows: original.receiveShadows,
            batchRange: original.batchRange, skinningBuffer: original.skinningBuffer, morphBuffer: original.morphBuffer)
        #expect(Meshlet3DEligibility.fallbackReason(custom) == "drawPass")
        let uniform = try #require(scene.camera.components[GlobalViewUniform.self])
        for mode: MeshletVisibilityMode3D in [.cpuReference, .gpu] {
            var items = [custom], state = Meshlet3DState()
            var settings = try #require(scene.camera.components[Environment3D.self]).meshVisibility
            settings.meshlets = mode
            let command = scene.device.createCommandQueue().makeCommandBuffer()
            let count = state.prepare(items: &items, view: scene.camera.id, projection: uniform.viewProjectionMatrix,
                settings: settings, command: command, device: scene.device)
            #expect(count.eligibleItems == 0 && count.gpuDraws == 0 && count.fallbackItems == 1)
            #expect(count.fallbackReasons["drawPass"] == 1 && state.output(for: scene.camera.id) == nil)
            #expect(items[0].meshletOverride == nil)
            let before = original.mesh.models[original.modelIndex].parts[original.partIndex]
            let after = items[0].mesh.models[items[0].modelIndex].parts[items[0].partIndex]
            #expect(after.indexBuffer === before.indexBuffer && after.vertexBuffer === before.vertexBuffer && after.indexCount == before.indexCount)
            await Self.complete(command)
        }
    }

    @Test
    func parallelPrefixHandlesGroupBoundariesAndMaximumProfileSize() async throws {
        let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
        let processor = try #require(scene.device.createMeshletVisibilityProcessor())
        let queue = scene.device.createCommandQueue()
        for clusterCount in [1, 255, 256, 257, 600, 65_536] {
            var positions: [Vector3] = [], indices: [UInt32] = [], mixed: [UInt32] = []
            positions.reserveCapacity(clusterCount * 3)
            indices.reserveCapacity(clusterCount * 3)
            for index in 0..<clusterCount {
                let inside = index % 7 != 2 && index % 13 != 6
                let x: Float = inside ? -0.5 : 2.5
                let y = Float(index % 19) * 0.03 - 0.27
                let first = UInt32(positions.count)
                positions.append(contentsOf: [[x, y, 0.5], [x + 0.01, y, 0.5], [x, y + 0.01, 0.5]])
                let triangle = [first, first + 1, first + 2]
                indices.append(contentsOf: triangle)
                if inside { mixed.append(contentsOf: triangle) }
            }
            let geometry = try MeshletGeometry.scan(positions: positions, indices: indices, maximumVertices: 3, maximumTriangles: 1)
            #expect(geometry.clusters.count == clusterCount)
            var descriptor = MeshDescriptor(name: "Parallel prefix boundary \(clusterCount)")
            descriptor.positions = MeshBuffer(positions)
            descriptor.indicies = indices
            let source = descriptor.getIndexBuffer(renderDevice: scene.device)
            let outside = Transform3D(translation: [4, 0, 0])
            let draws = [
                MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: source, transform: .identity),
                MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: source, transform: outside),
                MeshletVisibilityDraw(geometry: geometry, sourceIndexBuffer: source, transform: outside, forceVisible: true),
            ]
            let expected: [[UInt32]] = [mixed, [], indices]
            let command = queue.makeCommandBuffer()
            let output = try #require(processor.encode(on: command, viewProjection: .identity, draws: draws))
            await Self.complete(command)
            let arguments = Self.words(try await output.arguments.readData())
            let compacted = Self.words(try await output.indices.readData())
            #expect(output.drawCount == 3)
            for draw in 0..<3 {
                let first = draw * indices.count, argument = draw * 5
                #expect(Array(arguments[argument..<(argument + 5)]) == [UInt32(expected[draw].count), 1, UInt32(first), 0, 0],
                    "Incorrect exclusive prefix/indirect totals for \(clusterCount) clusters in draw \(draw).")
                #expect(Array(compacted[first..<(first + expected[draw].count)]) == expected[draw],
                    "Group boundaries must preserve exact source order for \(clusterCount) clusters in draw \(draw).")
            }
        }
    }
}
#endif
