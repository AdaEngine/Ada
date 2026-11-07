#if os(macOS) || os(Windows) || os(Linux)
@_spi(Internal) @testable import AdaApp
import AdaAssets
@testable import AdaCorePipelines
import AdaECS
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing
#if os(Windows)
import WinSDK
#endif

extension Render3DGPUTests.Benchmarks {
    private struct TerrainInstanceMeasurement: Codable {
        let mode: String
        let count: Int
        let runtimeEntities: Int
        let frameMilliseconds: Double
        let submittedFrameMilliseconds: Double
        let processCPUMilliseconds: Double?
        let drawCalls: Int
        let visibleInstances: Int
        let residentPlacementBytes: Int
        let processWorkingSetBytes: UInt64?
        let processCommitBytes: UInt64?
    }

    private func instanceMemory() -> (working: UInt64?, commit: UInt64?) {
        #if os(Windows)
        var counters = PROCESS_MEMORY_COUNTERS()
        counters.cb = DWORD(MemoryLayout<PROCESS_MEMORY_COUNTERS>.size)
        guard unsafe K32GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) else {
            return (nil, nil)
        }
        return (UInt64(counters.WorkingSetSize), UInt64(counters.PagefileUsage))
        #else
        return (nil, nil)
        #endif
    }

    private func instanceCPUSeconds() -> Double? {
        #if os(Windows)
        var creation = FILETIME(), exit = FILETIME(), kernel = FILETIME(), user = FILETIME()
        guard unsafe GetProcessTimes(GetCurrentProcess(), &creation, &exit, &kernel, &user) else {
            return nil
        }
        func ticks(_ time: FILETIME) -> UInt64 { (UInt64(time.dwHighDateTime) << 32) | UInt64(time.dwLowDateTime) }
        return (Double(ticks(kernel)) + Double(ticks(user))) * 1e-7
        #else
        return nil
        #endif
    }

    private func benchmarkTerrainFile(in directory: URL) async throws -> URL {
        // A single reusable static triangle, with faces visible from either side.
        let model = """
        {"asset":{"version":"2.0"},"buffers":[{
        "uri":"data:application/octet-stream;base64,AAAAAAAAgD8AAAAAAACAvwAAgL8AAAAAAACAPwAAgL8AAAAAAAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/AAAAAAAAAAAAAIA/","byteLength":72}],
        "bufferViews":[{"buffer":0,"byteLength":36},{"buffer":0,"byteOffset":36,"byteLength":36}],
        "accessors":[{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[-1,-1,0],"max":[1,1,0]},{"bufferView":1,"componentType":5126,"count":3,"type":"VEC3"}],
        "materials":[{"doubleSided":true,"pbrMetallicRoughness":{"baseColorFactor":[0.2,0.7,0.3,1]}}],
        "meshes":[{"primitives":[{"attributes":{"POSITION":0,"NORMAL":1},"material":0}]}],"nodes":[{"mesh":0}],"scenes":[{"nodes":[0]}],"scene":0}
        """
        try Data(model.utf8).write(to: directory.appendingPathComponent("prop.gltf"))
        var rows: [[TerrainRegionInstance]] = [[], []]
        for index in 0..<100_000 {
            let x = index % 500, z = index / 500, region = x / 256
            rows[region].append(try .init(id: UInt64(index + 1), prototypeID: 7, localPosition: [Float(x % 256), 1, Float(z)], scale: [0.35, 0.35, 0.35], flags: []))
        }
        let regions = rows.enumerated().map { TerrainRegionAsset(x: Int32($0.offset), z: 0, tiles: [], pages: [], instances: $0.element) }
        let file = directory.appendingPathComponent("benchmark.aterrain")
        _ = try await AssetsManager.saveTerrainRegions(
            regions,
            manifest: .init(meshPrototypes: [.init(id: 7, assetPath: "prop.gltf", maximumDistance: 2_000)]),
            at: file.path
        )
        return file
    }

    private func measureTerrainInstances(
        _ scene: Render3DGPUTests.DebugViews.Scene,
        owner: Entity,
        mode: String,
        frames: Int
    ) async throws -> (TerrainInstanceMeasurement, Image) {
        _ = try await scene.render(.albedo, frames: 3)
        let renderWorld = try #require(scene.app.getSubworldBuilder(by: .renderWorld)?.main)
        let statistics = try #require(renderWorld.getResource(Render3DVisibilityStatistics.self))
        let cpuStart = instanceCPUSeconds()
        let start = ContinuousClock.now
        for _ in 0..<frames { try await scene.app.update() }
        let submitted = start.duration(to: .now)
        let image = try await scene.render(.albedo, frames: 0)
        let completed = start.duration(to: .now)
        let cpuEnd = instanceCPUSeconds()
        func milliseconds(_ duration: Duration) -> Double {
            (Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18) * 1_000 / Double(frames)
        }
        let views = statistics.snapshots.filter { $0.key.hasSuffix(":camera") }.values
        let memory = instanceMemory()
        let result = TerrainInstanceMeasurement(
            mode: mode,
            count: 100_000,
            runtimeEntities: scene.app.main.getEntities().count,
            frameMilliseconds: milliseconds(completed),
            submittedFrameMilliseconds: milliseconds(submitted),
            processCPUMilliseconds: cpuStart.flatMap { start in cpuEnd.map { ($0 - start) * 1_000 / Double(frames) } },
            drawCalls: views.reduce(0) { $0 + $1.drawCalls },
            visibleInstances: views.reduce(0) { $0 + $1.visibleMeshes },
            residentPlacementBytes: owner.components[Terrain3DSourceSurface.self]?.storage.residentInstanceBytes ?? 0,
            processWorkingSetBytes: memory.working,
            processCommitBytes: memory.commit
        )
        try #require(result.visibleInstances == 100_000 && result.drawCalls > 0, "All 100k terrain props must pass actual camera visibility")
        var greenPixels = 0
        for y in 0..<image.height {
            for x in 0..<image.width {
                let color = image.getPixel(x: x, y: y)
                if color.green > color.red + 0.1 && color.green > color.blue + 0.1 { greenPixels += 1 }
            }
        }
        try #require(greenPixels > 100, "The actual prop material must produce visible pixels, not an empty comparison")
        return (result, image)
    }

    /// No universal timing threshold: compare actual frames, geometry submission and memory on this machine.
    @Test(.enabled(if: Render3DGPUTests.Benchmarks.enabled))
    func terrainHundredThousandInstances() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AdaTerrainPerf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await benchmarkTerrainFile(in: directory)
        let scene = try await Render3DGPUTests.DebugViews.makeScene()
        for entity in scene.app.main.getEntities() where entity.components[Mesh3DComponent.self] != nil {
            scene.app.main.removeEntity(entity.id, recursively: true)
        }
        try scene.configure {
            $0.antiAliasing = .none
            $0.ambientOcclusion.isEnabled = false
            $0.shadows.isEnabled = false
            $0.localShadows.isEnabled = false
            $0.screenSpaceReflection.isEnabled = false
            $0.screenSpaceGI.isEnabled = false
            $0.fog.isEnabled = false
            $0.postProcess.autoExposure.isEnabled = false
            $0.postProcess.bloom.isEnabled = false
        }
        scene.camera.components[Transform.self] = Transform(rotation: Quat(axis: .right, angle: .pi / 4), position: [250, 250, -200])
        scene.camera.components[Camera.self]?.projection = .orthographic(.init(near: 0.1, far: 2_000, scale: Float(scene.target.width) / 620))
        let owner = scene.app.main.spawn("100k authored terrain props") {
            Transform()
            Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        let clock = ContinuousClock(), deadline = clock.now.advanced(by: .seconds(60))
        while clock.now < deadline {
            await scene.app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let cells = owner.children.compactMap { entity -> (Entity, Mesh3DInstancesComponent)? in
            entity.components[Mesh3DInstancesComponent.self].map { (entity, $0) }
        }
        try #require(cells.reduce(0) { $0 + $1.1.instances.count } == 100_000)
        #expect(cells.count < 1_000)
        let frames = max(1, Int(ProcessInfo.processInfo.environment["ADAENGINE_PERF_FRAMES"] ?? "") ?? 30)
        let (batched, batchedImage) = try await measureTerrainInstances(scene, owner: owner, mode: "terrain spatial batches", frames: frames)
        for (cell, component) in cells {
            scene.app.main.removeEntity(cell.id, recursively: true)
            let group = scene.app.main.spawn("Individual props from cell \(cell.id)") { Transform() }
            owner.addChild(group)
            for placement in component.instances {
                // This fixture uses axis-aligned TRS. Preserve its exact scale rather than
                // decomposing a scaled matrix through the separate legacy rotation accessor.
                let pose = Transform(scale: [placement.transform.x.x, placement.transform.y.y, placement.transform.z.z], position: placement.transform.origin)
                try #require(pose.matrix == placement.transform, "Both benchmark paths must submit identical placement matrices")
                let child = scene.app.main.spawn("Prop \(placement.id)") {
                    pose
                    Mesh3DComponent(mesh: component.mesh, materials: component.materials, castShadows: component.castShadows, receiveShadows: component.receiveShadows)
                }
                group.addChild(child)
            }
        }
        let (entities, entitiesImage) = try await measureTerrainInstances(scene, owner: owner, mode: "one entity per prop, shared assets", frames: frames)
        #expect(batched.runtimeEntities < 1_000)
        #expect(entities.runtimeEntities >= 100_000)
        if let path = ProcessInfo.processInfo.environment["ADAENGINE_GOLDEN_OUTPUT"] {
            let output = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try batchedImage.writePNG(to: output.appendingPathComponent("terrain-100k-batched.png"))
            try entitiesImage.writePNG(to: output.appendingPathComponent("terrain-100k-entities.png"))
        }
        #expect(batchedImage.data == entitiesImage.data, "Batching must preserve the rendered scene")
        let data = try JSONEncoder().encode([batched, entities])
        let report = try #require(String(data: data, encoding: .utf8))
        print("TERRAIN-100K-BENCHMARK \(report)")
        if let path = ProcessInfo.processInfo.environment["ADAENGINE_TERRAIN_PERF_OUTPUT"] {
            try data.write(to: URL(fileURLWithPath: path))
        }
    }
}
#endif
