@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Background builds return before publication and prepare only the requested tile budget each frame without publishing partial terrain")
    func backgroundPreparationAndAtomicPublication() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        await app.main.runScheduler(.preUpdate)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        #expect(owner.children.isEmpty)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var observedPreparation = false
        var previous = 0
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            let status = try #require(owner.components[Terrain3DSourceStatus.self])
            if status.isReady { break }
            #expect(status.error == nil)
            #expect(owner.children.isEmpty)
            #expect(owner.components[Terrain3DSourceSurface.self] == nil)
            #expect(status.preparedTileCount <= previous + 1)
            previous = status.preparedTileCount
            if status.preparedTileCount > 0 {
                observedPreparation = true
                #expect(status.pendingTileCount == 16)
                #expect(status.preparedTileCount < status.pendingTileCount)
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observedPreparation)
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(try buffers(owner).count == 16)
    }

    @Test("Changing the source during incremental preparation cancels the old generation and never publishes its tiles")
    func supersedesPendingGeneration() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let firstDirectory = directory.appendingPathComponent("First", isDirectory: true)
        let secondDirectory = directory.appendingPathComponent("Second", isDirectory: true)
        for child in [firstDirectory, secondDirectory] { try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let first = try await save(authored, in: firstDirectory)
        var secondTerrain = Terrain3D(resolution: 65, size: 64)
        secondTerrain.heights = Array(repeating: 7, count: 65 * 65)
        let second = try await save(secondTerrain, in: secondDirectory)
        let app = try await makeApp()
        var source = Terrain3DSource(source: first.path, generatesCollision: false, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        let owner = app.main.spawn("Terrain asset") {
            Transform(); source
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if let status = owner.components[Terrain3DSourceStatus.self], status.preparedTileCount > 0, !status.isReady { break }
            if owner.components[Terrain3DSourceStatus.self]?.isReady == true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.children.isEmpty)
        source.source = second.path
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(try buffers(owner).count == 1)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage.height(atSample: .init(x: 10, z: 10)) == 7)
        for _ in 0..<4 { await app.main.runScheduler(.preUpdate); await Task.yield() }
        #expect(try buffers(owner).count == 1)
    }

    @Test("A queued source makes progress while earlier sources continuously follow a moving camera")
    func queuedSourcesDoNotStarve() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(storage, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        let owners = (0..<3).map { index in
            app.main.spawn("Terrain \(index)") {
                Transform(); source
            }
        }
        let camera = app.main.spawn("Moving camera") {
            Transform(position: [128, 64, 128]); Camera()
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var frame = 0
        while clock.now < deadline {
            camera.components[Transform.self] = Transform(position: [128 + Float(frame) / 100, 64, 128])
            await app.main.runScheduler(.preUpdate)
            if owners.allSatisfy({ $0.components[Terrain3DSourceSurface.self] != nil }) { break }
            frame += 1
            try await Task.sleep(for: .milliseconds(1))
        }
        let stages = owners.map { $0.components[Terrain3DSourceStatus.self] }
        #expect(owners.allSatisfy { $0.components[Terrain3DSourceSurface.self] != nil }, "After \(frame) scheduler updates: \(String(describing: stages))")
        #expect(try owners.map { try buffers($0).count } == [16, 16, 16])
    }

    @Test("Failed replacement prepares moved resident collision incrementally and holds simulation until publication")
    func failureFallbackRespectsFrameBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(storage, in: directory)
        let app = try await makeApp(physics: true)
        app.main.insertResource(FixedTime(deltaTime: 1 / 60))
        var source = Terrain3DSource(source: file.path, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        let parent = app.main.spawn("Environment") { Transform() }
        let owner = app.main.spawn("Terrain") {
            Transform(); source
        }
        parent.addChild(owner)
        let body = app.main.spawn("Waiting body") {
            Transform(position: [128, 5, 128])
            PhysicsBody3DComponent(shapes: [.generateSphere(radius: 0.5)], mass: 1, mode: .dynamic)
        }
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        source.source = directory.appendingPathComponent("missing.aterrain").path
        owner.components[Terrain3DSource.self] = source
        parent.components[Transform.self] = Transform(position: [0, 2, 0])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var previous = 0
        var observedPreparation = false
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            let status = try #require(owner.components[Terrain3DSourceStatus.self])
            if status.error != nil { break }
            #expect(status.preparedTileCount <= previous + 1)
            previous = status.preparedTileCount
            observedPreparation = observedPreparation || previous > 0
            await app.main.runScheduler(.physicsSync)
            await app.main.runScheduler(.physicsStep)
            await app.main.runScheduler(.physicsWriteback)
            #expect(body.components[Transform.self]?.position.y == 5)
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observedPreparation)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [140, 10, 128], to: [140, -10, 128], radius: 0.25)
        #expect(fraction > 0.38 && fraction < 0.40)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Reverting a queued source to its cached missing URI releases its FIFO position for later sources")
    func cachedFailureDoesNotBlockQueue() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = try TerrainHeightStorage()
        try storage.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(storage, in: directory)
        let missing = directory.appendingPathComponent("missing.aterrain").path
        let app = try await makeApp()
        var failedSource = Terrain3DSource(source: missing, generatesCollision: false, maximumTileUpdatesPerFrame: 1)
        let failed = app.main.spawn("Initially failed source") { Transform(); failedSource }
        await settle(app)
        #expect(failed.components[Terrain3DSourceStatus.self]?.error != nil)
        let valid = Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        for index in 0..<2 { app.main.spawn("Worker blocker \(index)") { Transform(); valid } }
        await app.main.runScheduler(.preUpdate)
        failedSource.source = file.path
        failed.components[Terrain3DSource.self] = failedSource
        await app.main.runScheduler(.preUpdate)
        #expect(failed.components[Terrain3DSourceStatus.self]?.isPreparing == true)
        #expect(failed.components[Terrain3DSourceSurface.self] == nil)
        failedSource.source = missing
        failed.components[Terrain3DSource.self] = failedSource
        let later = app.main.spawn("Later valid source") { Transform(); valid }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        var frames = 0
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            frames += 1
            if later.components[Terrain3DSourceSurface.self] != nil { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(failed.components[Terrain3DSourceStatus.self]?.error != nil)
        let laterStage = String(describing: later.components[Terrain3DSourceStatus.self])
        let failedStage = String(describing: failed.components[Terrain3DSourceStatus.self])
        #expect(later.components[Terrain3DSourceStatus.self]?.isReady == true,
            "After \(frames) scheduler updates: later=\(laterStage), failed=\(failedStage)")
        #expect(try buffers(later).count == 16)
    }
}
