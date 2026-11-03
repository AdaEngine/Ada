#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaUtils
import Foundation
import Math
import Testing

@testable import AdaCorePipelines

extension Render3DGPUTests {
    /// P0 baseline only: exercises production extraction, batching, Hi-Z and rasterization, without meshlets.
    @MainActor
    @Suite("Meshlet preparation baseline")
    struct MeshletBaseline {
        nonisolated private static var enabled: Bool {
            GoldenFrame.isEnabled && ProcessInfo.processInfo.environment["ADAENGINE_MESHLET_BASELINE"] == "1"
        }

        struct Census: Codable {
            var candidates: Int
            var visibleMeshes: Int
            var triangles: Int
            var batches: Int
            var batchSizeHistogram: [String: Int]
            var lodInstances: [Int]
            var uniqueParts: Int
            var singletonTriangles: Int
            var uniqueGeometryBytes: Int
            var compactedIndexCeilingBytes: Int
            var instanceBufferBytes: Int
            var geometryDigest: String
        }

        struct Measurement: Codable {
            var workload: String
            var subdivisions: Int
            var hiZ: Bool
            var round: Int
            var census: Census
            var updateMilliseconds: [Double]
            /// GPU-drained throughput windows; native WebGPU amortizes its event-pump timer over 90 frames.
            var windowMillisecondsPerFrame: [Double]
            var drainInclusiveMillisecondsPerFrame: Double
            var extractionMilliseconds: [Double]
            var listPreparationMilliseconds: [Double]
            var mainNodeMilliseconds: [Double]
            var gpuPasses: [Render3DPerformanceMetrics.Sample]
        }

        struct Report: Codable {
            var schema = 1
            var backend: String
            var completionProtocol: String
            var os: String
            var width: Int
            var height: Int
            var warmupFrames: Int
            var measuredFrames: Int
            var rounds: Int
            var maxFramesInFlight: Int
            var submissionWindowFrames: Int
            var measurements: [Measurement]
        }

        private static func setting(_ suffix: String, default fallback: Int, range: ClosedRange<Int>) throws -> Int {
            let key = "ADAENGINE_MESHLET_BASELINE_" + suffix
            guard let raw = ProcessInfo.processInfo.environment[key] else { return fallback }
            let value = try #require(Int(raw), "\(key) must be an integer")
            try #require(range.contains(value), "\(key) is outside \(range)")
            return value
        }

        static func milliseconds(since start: ContinuousClock.Instant) -> Double {
            let elapsed = start.duration(to: .now).components
            return Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15
        }

        /// Completion covers previously submitted work on the device queue; no texture copy/readback in timing.
        static func drain(_ device: RenderDevice) async {
            let fence = device.createCommandQueue().makeCommandBuffer()
            await withCheckedContinuation { continuation in
                fence.addCompletedHandler { continuation.resume() }
                fence.commit()
            }
        }

        static func census(_ scene: MeshletBaselineFixtures.Scene, world: World) throws -> Census {
            let lists = try #require(world.getResource(VisibleMesh3DLists.self))
            let count = lists.count(view: scene.camera.id, pass: -1)
            let items = lists.items(view: scene.camera.id, pass: -1)
            var histogram: [String: Int] = [:], seen = Set<ObjectIdentifier>()
            var singletons = 0, geometryBytes = 0
            var digest = FrameDigest3D()
            for item in items {
                let instances = Int(item.batchRange?.count ?? 0)
                histogram[String(instances), default: 0] += 1
                let part = item.mesh.models[item.modelIndex].parts[item.partIndex]
                if instances == 1 { singletons += part.indexCount / 3 }
                if seen.insert(ObjectIdentifier(part.indexBuffer)).inserted {
                    geometryBytes += part.indexBuffer.length + part.vertexBuffer.length
                    for position in part.meshDescriptor.positions { digest.combine(Vector4(position, 1)) }
                    for index in part.meshDescriptor.indicies { digest.combine(UInt64(index)) }
                }
            }
            return Census(candidates: count.candidates, visibleMeshes: count.visibleMeshes, triangles: count.triangles,
                batches: items.count, batchSizeHistogram: histogram, lodInstances: count.lodInstances, uniqueParts: seen.count, singletonTriangles: singletons,
                uniqueGeometryBytes: geometryBytes, compactedIndexCeilingBytes: singletons * 3 * MemoryLayout<UInt32>.stride,
                instanceBufferBytes: lists.buffers(view: scene.camera.id, pass: -1).instances?.buffer?.length ?? 0,
                geometryDigest: String(digest.value, radix: 16))
        }

        /// Separate diagnostic phase, excluded from render timings. Includes real extraction and list uploads.
        static func cpuDiagnostics(_ scene: MeshletBaselineFixtures.Scene, world: World) async throws -> ([Double], [Double], [Double]) {
            var extraction: [Double] = [], preparation: [Double] = []
            var lists = VisibleMesh3DLists(), materials = PBR3DUniforms()
            let uniform = try #require(scene.camera.components[GlobalViewUniform.self])
            let settings = try #require(scene.camera.components[Environment3D.self]).meshVisibility
            for _ in 0..<12 {
                let start = ContinuousClock.now
                await RenderWorldExctractor().exctract(from: scene.app.main, to: world)
                extraction.append(milliseconds(since: start))
                let sources = try #require(world.getResource(ExtractedMesh3DSources.self)).meshes
                let listStart = ContinuousClock.now
                materials.beginFrame()
                lists.prepare(sources: sources, view: scene.camera.id, pass: -1, viewMatrix: uniform.viewMatrix,
                    projection: uniform.projectionMatrix, cullingProjection: uniform.viewProjectionMatrix,
                    settings: settings, device: scene.device, materials: &materials)
                preparation.append(milliseconds(since: listStart))
                await drain(scene.device)
            }
            let diagnostics = RenderGraphDiagnostics(isEnabled: true, capacity: 4)
            world.insertResource(diagnostics)
            defer { diagnostics.configure(isEnabled: false) }
            var nodes: [Double] = []
            for _ in 0..<12 {
                try await scene.app.update()
                await drain(scene.device)
                let node = try #require(diagnostics.records.flatMap(\.nodes).last { $0.typeName.contains("Main3DRenderNode") })
                nodes.append(node.durationMilliseconds)
            }
            return (Array(extraction.dropFirst(3)), Array(preparation.dropFirst(3)), Array(nodes.dropFirst(3)))
        }

        private static func measure(
            _ scene: MeshletBaselineFixtures.Scene, workload: String, subdivisions: Int, hiZ: Bool, round: Int, warmup: Int, frames: Int
        ) async throws -> (Measurement, Image) {
            let world = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
            var environment = try #require(scene.camera.components[Environment3D.self])
            environment.gpuOcclusionEnabled = hiZ
            scene.camera.components[Environment3D.self] = environment
            world.insertResource(Render3DPerformanceMetrics(warmupSamples: 0, synchronizesPasses: false))
            // WebGPU uploads are queue.writeBuffer operations ordered with submitted draws, so ring reuse
            // does not overwrite CPU-mapped memory. Use larger throughput windows to amortize native event
            // pumping. Metal writes shared memory directly and retains the conservative in-flight bound.
            let window = GoldenFrame.activeBackend == .webgpu ? min(frames, 90) : max(1, unsafe RenderEngine.configurations.maxFramesInFlight)
            for index in 0..<warmup {
                try await scene.app.update()
                if (index + 1) % window == 0 { await drain(scene.device) }
            }
            await drain(scene.device)
            var updates: [Double] = [], windows: [Double] = []
            let totalStart = ContinuousClock.now
            var frame = 0
            while frame < frames {
                let count = min(window, frames - frame), start = ContinuousClock.now
                for _ in 0..<count {
                    let updateStart = ContinuousClock.now
                    try await scene.app.update()
                    updates.append(milliseconds(since: updateStart))
                }
                await drain(scene.device)
                windows.append(milliseconds(since: start) / Double(count))
                frame += count
            }
            let wall = milliseconds(since: totalStart) / Double(frames)
            let counts = try census(scene, world: world)
            try #require(counts.batches > 0 && counts.triangles > 0)
            if workload == "partial" {
                let source = try #require(world.getResource(ExtractedMesh3DSources.self)?.meshes.first)
                let uniform = try #require(scene.camera.components[GlobalViewUniform.self])
                let corner = uniform.viewProjectionMatrix * source.transform * Vector4(source.mesh.bounds.max, 1)
                #expect(corner.x > corner.w, "The target must actually extend beyond the camera's right clip plane")
            } else if workload == "instances" {
                #expect(counts.batchSizeHistogram == ["1600": 1], "Repeated geometry must remain one instanced batch")
                #expect(counts.singletonTriangles == 0)
            } else if workload == "smallParts" {
                #expect(counts.batchSizeHistogram == ["1": 256])
            }
            if hiZ {
                try #require(world.getResource(GPUVisibility3DState.self)?.output(for: scene.camera.id) != nil,
                    "Hi-Z requested but the GPU processor fell back")
            }
            let image = try #require(try await scene.device.readImage(from: scene.target))
            // Actual raster output must contain more than a uniform clear color.
            let first = image.getPixel(x: 0, y: 0)
            let hasGeometry = stride(from: 0, to: image.height, by: max(1, image.height / 24)).contains { row in
                (0..<image.width).contains { image.getPixel(x: $0, y: row) != first }
            }
            #expect(hasGeometry)
            let cpu = try await cpuDiagnostics(scene, world: world)
            // Isolated pass timings are a separate serialized profiling phase, never mixed into throughput.
            let metrics = Render3DPerformanceMetrics(warmupSamples: 3, synchronizesPasses: true)
            world.insertResource(metrics)
            for _ in 0..<12 { try await scene.app.update() }
            await drain(scene.device)
            return (Measurement(workload: workload, subdivisions: subdivisions, hiZ: hiZ, round: round, census: counts,
                updateMilliseconds: updates, windowMillisecondsPerFrame: windows, drainInclusiveMillisecondsPerFrame: wall,
                extractionMilliseconds: cpu.0, listPreparationMilliseconds: cpu.1, mainNodeMilliseconds: cpu.2, gpuPasses: metrics.samples), image)
        }

        @Test(.enabled(if: Self.enabled))
        func recordsProductionBaseline() async throws {
            let width = try Self.setting("WIDTH", default: 1280, range: 64...4096)
            let height = try Self.setting("HEIGHT", default: 720, range: 64...4096)
            let frames = try Self.setting("FRAMES", default: 90, range: 3...3600)
            let warmup = try Self.setting("WARMUP", default: 60, range: 3...600)
            let rounds = try Self.setting("ROUNDS", default: 3, range: 1...20)
            let subdivisions = try Self.setting("SUBDIVISIONS", default: 512, range: 16...1024)
            let filter = ProcessInfo.processInfo.environment["ADAENGINE_MESHLET_BASELINE_FILTER"]
            let workloads = MeshletBaselineFixtures.Workload.allCases.filter { filter == nil || $0.rawValue == filter }
            try #require(!workloads.isEmpty, "Unknown workload filter")
            let output = ProcessInfo.processInfo.environment["ADAENGINE_MESHLET_BASELINE_OUTPUT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            if let output { try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true) }
            var measurements: [Measurement] = []
            for workload in workloads {
                let scene = try await MeshletBaselineFixtures.make(workload, size: [width, height], subdivisions: subdivisions)
                for round in 0..<rounds {
                    var images: [Image] = []
                    // Reverse the order every other pair; retain every raw sample rather than the best round.
                    for hiZ in round.isMultiple(of: 2) ? [false, true] : [true, false] {
                        let (sample, image) = try await Self.measure(scene, workload: workload.rawValue,
                            subdivisions: subdivisions, hiZ: hiZ, round: round, warmup: warmup, frames: frames)
                        measurements.append(sample)
                        images.append(image)
                        print("MESHLET BASELINE \(workload.rawValue) round=\(round) hiz=\(hiZ) "
                            + "wall-ms=\(sample.drainInclusiveMillisecondsPerFrame) batches=\(sample.census.batchSizeHistogram)")
                        if round == 0, let output { try image.writePNG(to: output.appendingPathComponent("\(workload.rawValue)-hiz-\(hiZ).png")) }
                    }
                    #expect(images[0].data == images[1].data, "Hi-Z must preserve baseline pixels")
                    if let output {
                        let report = Report(backend: GoldenFrame.activeBackend?.rawValue ?? "unknown",
                            completionProtocol: "native-queue-throughput-window-v1",
                            os: ProcessInfo.processInfo.operatingSystemVersionString, width: width, height: height,
                            warmupFrames: warmup, measuredFrames: frames, rounds: rounds,
                            maxFramesInFlight: unsafe RenderEngine.configurations.maxFramesInFlight,
                            submissionWindowFrames: GoldenFrame.activeBackend == .webgpu ? min(frames, 90) : max(1, unsafe RenderEngine.configurations.maxFramesInFlight),
                            measurements: measurements)
                        let encoder = JSONEncoder()
                        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                        try encoder.encode(report).write(to: output.appendingPathComponent("baseline.json"), options: .atomic)
                    }
                }
            }
        }
    }
}
#endif
