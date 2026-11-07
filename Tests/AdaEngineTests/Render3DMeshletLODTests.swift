#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
import AdaGeometry
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import AdaUtils
import Foundation
import Math
import Testing

private enum MeshletLODFixture {
    static let viewport = SizeInt(width: 480, height: 320)
    static let projection = Transform3D.perspective(fieldOfView: .degrees(60), aspectRatio: 1.5, zNear: 0.1, zFar: 500)

    struct Prepared {
        let positions: [Vector3]
        let indices: [UInt32]
        let base: MeshletGeometry
        let hierarchy: MeshletLODGeometry

        func mesh(device: RenderDevice) -> Mesh {
            var descriptor = MeshDescriptor(name: "Watertight adaptive meshlet plane")
            descriptor.positions = MeshBuffer(positions)
            descriptor.normals = MeshBuffer(Array(repeating: Vector3(0, 0, -1), count: positions.count))
            descriptor.indicies = indices
            descriptor.meshlets = base
            descriptor.meshletLOD = hierarchy
            return Mesh.generate(from: [descriptor], renderDevice: device)
        }
    }

    /// Each half has an independently selectable coarse parent. The middle cut therefore
    /// joins a coarse left boundary to fine right children without changing the planar silhouette.
    static func make(offset: Vector3 = .zero) throws -> Prepared {
        var positions: [Vector3] = []
        for row in 0..<3 {
            for column in 0..<5 { positions.append(Vector3(Float(column * 2 - 4), Float(row * 2 - 2), 0) + offset) }
        }
        var source: [UInt32] = []
        for column in 0..<4 {
            for row in 0..<2 {
                let a = UInt32(row * 5 + column), b = a + 5
                source.append(contentsOf: [a, b, a + 1, a + 1, b, b + 1])
            }
        }
        let base = try MeshletGeometry.scan(positions: positions, indices: source, maximumVertices: 64, maximumTriangles: 2)
        let combined = source + [0, 10, 2, 2, 10, 12, 2, 12, 4, 4, 12, 14]
        let geometry = try MeshletGeometry.scan(positions: positions, indices: combined, maximumVertices: 64, maximumTriangles: 2)
        var nodes: [MeshletLODNode] = []
        for column in 0..<4 {
            nodes.append(.init(parent: column < 2 ? 4 : 5, firstChild: 0, childCount: 0,
                firstCluster: column * 2, clusterCount: 2,
                minimum: Vector3(Float(column * 2 - 4), -2, 0) + offset,
                maximum: Vector3(Float(column * 2 - 2), 2, 0) + offset,
                error: 0, firstSourceIndex: column * 12, sourceIndexCount: 12))
        }
        nodes.append(.init(parent: nil, firstChild: 0, childCount: 2, firstCluster: 8, clusterCount: 1,
            minimum: Vector3(-4, -2, 0) + offset, maximum: Vector3(0, 2, 0) + offset,
            error: 0.1, firstSourceIndex: 0, sourceIndexCount: 24, level: 1))
        nodes.append(.init(parent: nil, firstChild: 2, childCount: 2, firstCluster: 9, clusterCount: 1,
            minimum: Vector3(0, -2, 0) + offset, maximum: Vector3(4, 2, 0) + offset,
            error: 0.5, firstSourceIndex: 24, sourceIndexCount: 24, level: 1))
        let hierarchy = try MeshletLODGeometry(positions: positions, sourceIndices: source, geometry: geometry, nodes: nodes, roots: [4, 5])
        return Prepared(positions: positions, indices: source, base: base, hierarchy: hierarchy)
    }

    static func cut(_ prepared: Prepared, distance: Float, pixelError: Float = 2) -> [Int] {
        MeshletLODSelection.selectedNodes(geometry: prepared.hierarchy, transform: .init(translation: [0, 0, distance]),
            viewProjection: projection, viewport: viewport, pixelError: pixelError)
    }

    static func indices(_ prepared: Prepared, nodes: [Int], transform: Transform3D, projection: Transform3D) -> [UInt32] {
        var selected = Set<Int>()
        for id in nodes {
            let node = prepared.hierarchy.nodes[id]
            selected.formUnion(node.firstCluster..<(node.firstCluster + node.clusterCount))
        }
        let frustum = MeshVisibilityFrustum3D(viewProjection: projection)
        var output: [UInt32] = []
        for (index, cluster) in prepared.hierarchy.geometry.clusters.enumerated() where selected.contains(index) {
            let local = AABB(min: cluster.minimum, max: cluster.maximum)
            if frustum.intersects(MeshVisibility3DMath.transformed(local, by: transform)) {
                output.append(contentsOf: prepared.hierarchy.geometry.indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)])
            }
        }
        return output
    }
}

@Suite("Hierarchical meshlet LOD settings and cuts")
struct Render3DMeshletLODSettingsTests {
    @Test func oldScenePayloadLeavesAdaptiveLODDisabled() throws {
        let old = try JSONDecoder().decode(Environment3D.self, from: Data("{}".utf8))
        #expect(old.meshVisibility.meshletLODPixelError == 0)
        var environment = Environment3D()
        environment.meshVisibility.meshlets = .gpu
        environment.meshVisibility.meshletLODPixelError = 2
        let restored = try JSONDecoder().decode(Environment3D.self, from: JSONEncoder().encode(environment))
        #expect(restored.meshVisibility.meshletLODPixelError == 2)
        #expect(MemoryLayout<MeshletLODNodeGPU>.stride == 48)
        #expect(MemoryLayout<MeshletLODNodeGPU>.offset(of: \.minimum) == 0)
        #expect(MemoryLayout<MeshletLODNodeGPU>.offset(of: \.maximum) == 16)
        #expect(MemoryLayout<MeshletLODNodeGPU>.offset(of: \.metadata) == 32)
    }

    @Test func distanceSelectsFineMixedAndCoarseNonoverlappingCuts() throws {
        let prepared = try MeshletLODFixture.make()
        let cases: [(Float, [Int], Int)] = [(6, [0, 1, 2, 3], 16), (30, [2, 3, 4], 10), (80, [4, 5], 4)]
        for (distance, expected, triangles) in cases {
            let cut = MeshletLODFixture.cut(prepared, distance: distance)
            #expect(cut == expected)
            var coverage = [Int](repeating: 0, count: prepared.indices.count / 3), selectedTriangles = 0
            let selected = Set(cut)
            for id in cut {
                let node = prepared.hierarchy.nodes[id]
                for index in (node.firstSourceIndex / 3)..<((node.firstSourceIndex + node.sourceIndexCount) / 3) { coverage[index] += 1 }
                for cluster in prepared.hierarchy.geometry.clusters[node.firstCluster..<(node.firstCluster + node.clusterCount)] {
                    selectedTriangles += cluster.indexCount / 3
                }
                var parent = node.parent
                while let id = parent {
                    #expect(!selected.contains(id), "A parent and any of its descendants must never share one render cut.")
                    parent = prepared.hierarchy.nodes[id].parent
                }
            }
            #expect(coverage.allSatisfy { $0 == 1 }, "Every original triangle span must be covered once, without gaps or duplicates.")
            #expect(selectedTriangles == triangles)
        }
        #expect(MeshletLODFixture.cut(prepared, distance: 80, pixelError: 0) == [0, 1, 2, 3])
        #expect(MeshletLODFixture.cut(prepared, distance: 0.05) == [0, 1, 2, 3], "Crossing the camera/error bound must refine to leaves.")
    }
}

extension Render3DGPUTests {
    @MainActor
    @Suite("Hierarchical meshlet LOD", .enabled(if: GoldenFrame.isEnabled))
    struct MeshletLOD {
        @Test("Mesh Terrain shaded and wireframe submit the same coarse triangles")
        func terrainWireframeMatchesRenderedMeshletCut() async throws {
            let scene = try await MeshletBaselineFixtures.empty(size: MeshletLODFixture.viewport, cameraPosition: [0, 56, 0])
            scene.camera.components[Transform.self] = Transform(rotation: Quat(axis: .right, angle: .pi / 2), position: [0, 56, 0])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaTerrainWireLOD-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let ground = try TriangleSurface.ground(size: [24, 24], cells: 16)
            let sections = try [Float(-12), 12].map { x in
                MeshTerrainBaseSection(surface: try ground.transformed(by: .init(translation: [x, 0, 0])), closure: .ground(bottomHeight: -4))
            }
            let asset = try await MeshTerrainDocumentAsset(document: .init(sections: sections)).compiling()
            try asset.encodedData().write(to: directory.appendingPathComponent("ground.atmesh"))
            let palette = TerrainMaterialPalette(layers: [.init(id: 1, name: "Grass")], fallbackLayerID: 1)
            let manifest = directory.appendingPathComponent("ground.aterrain")
            try TerrainManifestAsset(materials: palette, meshDocumentFileName: "ground.atmesh").encodedData().write(to: manifest)
            let terrain = scene.app.main.spawn("Terrain") {
                Transform()
                Terrain3DSource(source: manifest.path, generatesCollision: false)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while terrain.components[Terrain3DSourceStatus.self]?.isReady != true, ContinuousClock.now < deadline {
                try await scene.app.update()
                try await Task.sleep(for: .milliseconds(10))
            }
            let tiles = terrain.children.filter { $0.components[Mesh3DComponent.self] != nil }
            try #require(tiles.count == 2)
            let statistics = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.getResource(Render3DMeshletStatistics.self))
            let view = String(scene.camera.id)
            let shaded = try await Self.frame(scene, mode: .disabled, pixelError: 0, debug: .none)
            let shadedCount = try #require(statistics.snapshots[view])
            let wire = try await Self.frame(scene, mode: .disabled, pixelError: 0, debug: .wireframe)
            let wireCount = try #require(statistics.snapshots[view])
            let overlay = try await Self.frame(scene, mode: .disabled, pixelError: 0, debug: .shadedWireframe)
            #expect(wireCount.selectedLODLevels == shadedCount.selectedLODLevels)
            #expect(wireCount.cpuSubmittedTriangles == shadedCount.cpuSubmittedTriangles)
            #expect(wireCount.cpuSubmittedTriangles > 0 && wireCount.cpuSubmittedTriangles < 1024)

            var expectedTriangles = 0
            for tile in tiles {
                var drawable = try #require(tile.components[Mesh3DComponent.self])
                let part = try #require(drawable.mesh.models.first?.parts.first)
                let hierarchy = try #require(part.meshletLOD)
                var descriptor = part.meshDescriptor
                descriptor.meshletLOD = nil
                descriptor.indicies = hierarchy.roots.flatMap { id in
                    let node = hierarchy.nodes[id]
                    return hierarchy.geometry.clusters[node.firstCluster..<(node.firstCluster + node.clusterCount)].flatMap { cluster in
                        hierarchy.geometry.indices[cluster.firstIndex..<(cluster.firstIndex + cluster.indexCount)]
                    }
                }
                expectedTriangles += descriptor.indicies.count / 3
                drawable.mesh = Mesh.generate(from: [descriptor], renderDevice: scene.device)
                tile.components[Mesh3DComponent.self] = drawable
            }
            #expect(wireCount.cpuSubmittedTriangles == expectedTriangles, "The camera must select the coarse cut on both sections.")
            let referenceShaded = try await Self.frame(scene, mode: .disabled, pixelError: 0, debug: .none)
            let referenceWire = try await Self.frame(scene, mode: .disabled, pixelError: 0, debug: .wireframe)
            #expect(GoldenFrame.compare(shaded, referenceShaded, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            #expect(GoldenFrame.compare(wire, referenceWire, tolerance: GoldenFrame.activeTolerance).passes(GoldenFrame.activeTolerance))
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try overlay.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("mesh-terrain-lod-overlay.png"))
        }

        private static func words(_ data: Data) -> [UInt32] {
            stride(from: 0, to: data.count - data.count % 4, by: 4).map { offset -> UInt32 in
                let a = UInt32(data[offset]), b = UInt32(data[offset + 1]) << 8
                let c = UInt32(data[offset + 2]) << 16, d = UInt32(data[offset + 3]) << 24
                return a | b | c | d
            }
        }

        private static func complete(_ command: CommandBuffer) async {
            await withCheckedContinuation { continuation in
                command.addCompletedHandler { continuation.resume() }
                command.commit()
            }
        }

        private static func frame(
            _ scene: MeshletBaselineFixtures.Scene, mode: MeshletVisibilityMode3D, pixelError: Float, debug: DebugView3D = .albedo
        ) async throws -> Image {
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.meshVisibility.meshlets = mode
            environment.meshVisibility.meshletLODPixelError = pixelError
            environment.gpuOcclusionEnabled = false
            environment.debugView = debug
            environment.postProcess.autoExposure.isEnabled = false
            environment.postProcess.bloom.isEnabled = false
            scene.camera.components[Environment3D.self] = environment
            for _ in 0..<3 { try await scene.app.update() }
            return try #require(try await scene.device.readImage(from: scene.target))
        }

        private static func scene(_ prepared: MeshletLODFixture.Prepared) async throws -> MeshletBaselineFixtures.Scene {
            let scene = try await MeshletBaselineFixtures.empty(size: MeshletLODFixture.viewport, cameraPosition: .zero)
            var camera = try #require(scene.camera.components[Camera.self])
            camera.projection = .perspective(.init(near: 0.1, far: 500, fieldOfView: .degrees(60), aspectRation: 1.5))
            camera.backgroundColor = .black
            scene.camera.components[Camera.self] = camera
            let material = PBRMaterial()
            material.baseColorFactor = [0.8, 0.3, 0.12, 1]
            material.metallicFactor = 0
            material.roughnessFactor = 1
            scene.app.main.spawn("Adaptive watertight plane") {
                Mesh3DComponent(mesh: prepared.mesh(device: scene.device), materials: [material])
                Transform(position: [0, 0, 6])
            }
            return scene
        }

        @Test
        func gpuCutMatchesCPUIndicesAndRejectsOnlyInvisibleSelectedClusters() async throws {
            let prepared = try MeshletLODFixture.make()
            let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
            let processor = try #require(scene.device.createMeshletVisibilityProcessor())
            let mesh = prepared.mesh(device: scene.device)
            let source = try #require(mesh.models.first?.parts.first?.indexBuffer)
            let queue = scene.device.createCommandQueue()
            let shifted = MeshletLODFixture.projection * Transform3D(translation: [-6, 0, 0])
            let cases: [(Float, Transform3D, Float)] = [
                (6, MeshletLODFixture.projection, 2), (30, MeshletLODFixture.projection, 2), (80, MeshletLODFixture.projection, 2),
                (6, shifted, 2), (6, shifted, 64), (0.05, MeshletLODFixture.projection, 2),
            ]
            for (distance, projection, threshold) in cases {
                let transform = Transform3D(translation: [0, 0, distance])
                let cut = MeshletLODSelection.selectedNodes(geometry: prepared.hierarchy, transform: transform,
                    viewProjection: projection, viewport: MeshletLODFixture.viewport, pixelError: threshold)
                let expected = MeshletLODFixture.indices(prepared, nodes: cut, transform: transform, projection: projection)
                let draw = MeshletVisibilityDraw(geometry: prepared.base, sourceIndexBuffer: source, transform: transform,
                    lod: prepared.hierarchy, lodPixelError: threshold, viewport: MeshletLODFixture.viewport, lodViewProjection: projection)
                #expect(draw.maximumIndexCount == prepared.indices.count, "All hierarchy levels must share the validated base-cut capacity.")
                let command = queue.makeCommandBuffer()
                let output = try #require(processor.encode(on: command, viewProjection: projection, draws: [draw]))
                await Self.complete(command)
                let arguments = Self.words(try await output.arguments.readData())
                let actual = Self.words(try await output.indices.readData())
                #expect(Array(arguments.prefix(5)) == [UInt32(expected.count), 1, 0, 0, 0])
                #expect(Array(actual.prefix(expected.count)) == expected,
                    "The GPU cut must match CPU hierarchy selection and cluster rejection at distance \(distance), error \(threshold).")
                #expect(expected.count <= prepared.indices.count)
            }
            let disabled = MeshletVisibilityDraw(geometry: prepared.base, sourceIndexBuffer: source, transform: .init(translation: [0, 0, 80]),
                lod: prepared.hierarchy, lodPixelError: 0, viewport: MeshletLODFixture.viewport)
            #expect(disabled.lod == nil && disabled.geometry.id == prepared.base.id)
            let command = queue.makeCommandBuffer()
            let output = try #require(processor.encode(on: command, viewProjection: MeshletLODFixture.projection, draws: [disabled]))
            await Self.complete(command)
            #expect(Self.words(try await output.arguments.readData()).first == UInt32(prepared.indices.count))
            #expect(Array(Self.words(try await output.indices.readData()).prefix(prepared.indices.count)) == prepared.indices)

            // The same uploaded hierarchy must support different per-draw cuts in one command.
            let batch = [Float(6), 80].map { distance in
                MeshletVisibilityDraw(geometry: prepared.base, sourceIndexBuffer: source, transform: .init(translation: [0, 0, distance]),
                    lod: prepared.hierarchy, lodPixelError: 2, viewport: MeshletLODFixture.viewport, lodViewProjection: MeshletLODFixture.projection)
            }
            let batchedCommand = queue.makeCommandBuffer()
            let batched = try #require(processor.encode(on: batchedCommand, viewProjection: MeshletLODFixture.projection, draws: batch))
            await Self.complete(batchedCommand)
            let arguments = Self.words(try await batched.arguments.readData())
            let combined = Self.words(try await batched.indices.readData())
            #expect(Array(arguments.prefix(10)) == [48, 1, 0, 0, 0, 12, 1, 48, 0, 0])
            #expect(Array(combined.prefix(48)) == prepared.indices)
            let parents = MeshletLODFixture.indices(prepared, nodes: [4, 5], transform: .init(translation: [0, 0, 80]), projection: MeshletLODFixture.projection)
            #expect(Array(combined[48..<60]) == parents, "Shared hierarchy draws must not alias near/far LOD uniforms or their bounded output segments.")
        }

        @Test
        func nearMixedAndFarRenderedCutsPreserveLegacySilhouetteAndReduceTriangles() async throws {
            let prepared = try MeshletLODFixture.make(), scene = try await Self.scene(prepared)
            let render = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let statistics = try #require(render.getResource(Render3DMeshletStatistics.self))
            for (distance, triangles) in [(Float(6), 16), (30, 10), (80, 4)] {
                scene.camera.components[Transform.self] = Transform(position: [0, 0, 6 - distance])
                let original = try await Self.frame(scene, mode: .disabled, pixelError: 0)
                let cpu = try await Self.frame(scene, mode: .cpuReference, pixelError: 2)
                let cpuCount = try #require(statistics.snapshots[String(scene.camera.id)])
                #expect(cpu.data == original.data, "Mixed adjacent LODs must not create cracks or lose the plane silhouette.")
                #expect(cpuCount.cpuSubmittedTriangles == triangles && cpuCount.sourceTriangles == 16)
                #expect(cpuCount.lodSelectedTriangles == triangles)
                let gpu = try await Self.frame(scene, mode: .gpu, pixelError: 2)
                #expect(gpu.data == original.data)
                let count = try #require(statistics.snapshots[String(scene.camera.id)])
                if let output = render.getResource(Meshlet3DState.self)?.output(for: scene.camera.id) {
                    #expect(count.gpuDraws == 1 && count.lodGPUItems == 1)
                    #expect(Self.words(try await output.arguments.readData()).first == UInt32(triangles * 3))
                } else {
                    #expect(distance == 6 && count.fastPathTriangles == 16,
                        "An all-visible fast path must not bypass actual coarse parent selection at medium/far distance.")
                }
            }
        }

        @Test
        func coarseMapIsStableAndDisplaysSelectedParentCoverage() async throws {
            let prepared = try MeshletLODFixture.make(), scene = try await Self.scene(prepared)
            scene.camera.components[Transform.self] = Transform(position: [0, 0, -74])
            let render = try #require(scene.app.getSubworldBuilder(by: .renderWorld))
            let statistics = try #require(render.getResource(Render3DMeshletStatistics.self))
            let fine = try await Self.frame(scene, mode: .gpu, pixelError: 0.01, debug: .meshlets)
            let mapResources = try #require(render.getResource(MeshletMap3DResources.self))
            let allocatedBytes = mapResources.allocatedBytes
            #expect(allocatedBytes > 0)
            let fineCount = try #require(statistics.snapshots[String(scene.camera.id)])
            #expect(fineCount.selectedLODLevels == [0: 4] && fineCount.lodSelectedTriangles == 16)
            let coarse = try await Self.frame(scene, mode: .gpu, pixelError: 2, debug: .meshlets)
            let coarseCount = try #require(statistics.snapshots[String(scene.camera.id)])
            #expect(coarseCount.selectedLODLevels == [1: 2] && coarseCount.lodSelectedTriangles == 4)
            let repeated = try await Self.frame(scene, mode: .gpu, pixelError: 2, debug: .meshlets)
            #expect(coarse.data == repeated.data)
            let coarseAllocation = try #require(render.getResource(MeshletMap3DResources.self)).allocatedBytes
            #expect(coarseAllocation == allocatedBytes)
            let disabled = try await Self.frame(scene, mode: .gpu, pixelError: 0, debug: .meshlets)
            let disabledAllocation = try #require(render.getResource(MeshletMap3DResources.self)).allocatedBytes
            #expect(disabled.data == fine.data && disabledAllocation == allocatedBytes,
                "Disabling LOD must reuse the hierarchy map stream and draw its exact leaf cut.")
            let coarseAgain = try await Self.frame(scene, mode: .gpu, pixelError: 2, debug: .meshlets)
            let reenabledAllocation = try #require(render.getResource(MeshletMap3DResources.self)).allocatedBytes
            #expect(coarseAgain.data == coarse.data && reenabledAllocation == allocatedBytes)
            #expect(coarse.data != fine.data, "The map must show the selected coarse parent clusters, not keep coloring finest leaves.")
            var covered = 0, mismatchedCoverage = 0
            for y in 0..<fine.height { for x in 0..<fine.width {
                let a = fine.getPixel(x: x, y: y), b = coarse.getPixel(x: x, y: y)
                let fineCovered = max(a.red, a.green, a.blue) > 0.05
                let coarseCovered = max(b.red, b.green, b.blue) > 0.05
                if fineCovered { covered += 1 }
                if fineCovered != coarseCovered { mismatchedCoverage += 1 }
            } }
            #expect(covered > 100 && mismatchedCoverage < 4)
            try FileManager.default.createDirectory(at: GoldenFrame.outputDirectory, withIntermediateDirectories: true)
            try fine.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("meshlet-lod-fine-map.png"))
            try coarse.writePNG(to: GoldenFrame.outputDirectory.appendingPathComponent("meshlet-lod-coarse-map.png"))
        }

        @Test
        func hierarchySidecarLoadPreservesV1WhenMissingStaleOrCorrupt() async throws {
            let prepared = try MeshletLODFixture.make()
            let scene = try await MeshletBaselineFixtures.empty(size: [32, 32])
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ada-meshlet-lod-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            var binary = Data()
            func word(_ value: UInt32) { for shift in stride(from: 0, to: 32, by: 8) { binary.append(UInt8((value >> shift) & 255)) } }
            for position in prepared.positions { word(position.x.bitPattern); word(position.y.bitPattern); word(position.z.bitPattern) }
            let indexOffset = binary.count
            for index in prepared.indices { word(index) }
            try binary.write(to: directory.appendingPathComponent("plane.bin"))
            let object: [String: Any] = [
                "asset": ["version": "2.0"], "scene": 0, "scenes": [["nodes": [0]]], "nodes": [["mesh": 0]],
                "buffers": [["uri": "plane.bin", "byteLength": binary.count]],
                "bufferViews": [["buffer": 0, "byteOffset": 0, "byteLength": indexOffset],
                                ["buffer": 0, "byteOffset": indexOffset, "byteLength": prepared.indices.count * 4]],
                "accessors": [["bufferView": 0, "componentType": 5126, "count": prepared.positions.count, "type": "VEC3"],
                              ["bufferView": 1, "componentType": 5125, "count": prepared.indices.count, "type": "SCALAR"]],
                "materials": [["pbrMetallicRoughness": ["baseColorFactor": [1, 1, 1, 1], "metallicFactor": 0, "roughnessFactor": 1]]],
                "meshes": [["primitives": [["attributes": ["POSITION": 0], "indices": 1, "material": 0]]]],
            ]
            let source = try JSONSerialization.data(withJSONObject: object)
            let v1 = try MeshletSidecar(parts: [.init(meshIndex: 0, partIndex: 0, geometry: prepared.base)],
                maximumVertices: 64, maximumTriangles: 2).encoded()
            let valid = try MeshletLODSidecar(parts: [.init(meshIndex: 0, partIndex: 0, geometry: prepared.hierarchy)],
                maximumVertices: 64, maximumTriangles: 2).encoded()
            let moved = try MeshletLODFixture.make(offset: [0.25, 0, 0])
            let stale = try MeshletLODSidecar(parts: [.init(meshIndex: 0, partIndex: 0, geometry: moved.hierarchy)],
                maximumVertices: 64, maximumTriangles: 2).encoded()
            let cases: [(String, Data?)] = [("v1-only", nil), ("valid", valid), ("stale", stale), ("corrupt", Data([1, 2, 3]))]
            for (name, hierarchy) in cases {
                let file = directory.appendingPathComponent(name + ".gltf")
                try source.write(to: file)
                try v1.write(to: file.appendingPathExtension("meshlets"))
                if let hierarchy { try hierarchy.write(to: file.appendingPathExtension("meshletlod")) }
                let model = try #require(try await AssetsManager.load(ModelAsset3D.self, at: file.path).asset)
                let part = try #require(model.meshes.first?.models.first?.parts.first)
                #expect(part.indexCount == 48 && part.meshDescriptor.indicies == prepared.indices)
                #expect(part.meshlets != nil, "An optional hierarchy failure must retain the valid v1 source partition.")
                #expect((part.meshletLOD != nil) == (name == "valid"))
                if name == "valid" {
                    let attached = try #require(part.meshletLOD)
                    #expect(attached.baseIndexCount == 48 && attached.nodes.count == 6 && attached.geometry.indices.count == 60)
                    var changed = part
                    changed.indexBuffer = part.meshDescriptor.getIndexBuffer(renderDevice: scene.device)
                    #expect(changed.meshletLOD == nil, "Changing the source generation invalidates the hierarchy together with v1 clustering.")
                } else if name != "v1-only" {
                    #expect(model.importWarnings.contains { $0.lowercased().contains("meshlet") })
                }
            }
        }
    }
}
#endif
