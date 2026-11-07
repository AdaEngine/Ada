@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

private actor TerrainSavePauseGate {
    var paused = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?

    func pause() async {
        paused = true
        if released {
            return
        }
        await withCheckedContinuation { continuation = $0 }
    }

    func resume() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

extension TerrainSourceRuntimeTests {
    @Test("A paused save honours source cancellation while pose and later height changes publish without losing its snapshot", arguments: [0, 1, 2, 3])
    func saveDoesNotFreezeLifecycle(change: Int) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let replacementDirectory = try self.directory()
        defer { try? FileManager.default.removeItem(at: replacementDirectory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        var replacement = Terrain3D(resolution: 65, size: 64)
        replacement.heights = Array(repeating: 1, count: 65 * 65)
        let replacementFile = try await save(replacement, in: replacementDirectory)
        let originalBytes = try Data(contentsOf: file)
        let app = try await makeApp(physics: true)
        var source = Terrain3DSource(source: file.path, streamingRadius: nil)
        let owner = app.main.spawn("Terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(4, at: .init(x: 10, z: 10))
        await settle(app)
        let before = try buffers(owner)
        let gate = TerrainSavePauseGate()
        defer { Task { await gate.resume() } }
        owner.components[Terrain3DSave.self] = .init(storage: storage, onProgress: { _, _ in await gate.pause() })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline, !(await gate.paused) {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.paused)
        switch change {
        case 0:
            source.source = ""
            owner.components[Terrain3DSource.self] = source
        case 1:
            source.source = replacementFile.path
            owner.components[Terrain3DSource.self] = source
        case 2: owner.components[Transform.self] = Transform(position: [0, 3, 0])
        default: try storage.setHeight(8, at: .init(x: 10, z: 10))
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let physics = try #require(app.main.physicsWorld3D)
        switch change {
        case 0:
            #expect(owner.components[Terrain3DSourceSurface.self] == nil)
            #expect(owner.children.isEmpty)
            #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01) == 1)
        case 1:
            #expect(owner.components[Terrain3DSourceSurface.self]?.storage !== storage)
            let fraction = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01)
            #expect(fraction > 0.44 && fraction < 0.46)
        case 2:
            let fraction = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01)
            #expect(fraction > 0.34 && fraction < 0.36)
        default:
            #expect(try buffers(owner) != before)
            let fraction = physics.sphereCastFraction(from: [-22, 20, -22], to: [-22, -20, -22], radius: 0.01)
            #expect(fraction > 0.28 && fraction < 0.31)
        }
        await gate.resume()
        await finishSave(app, owner: owner)
        if change < 2 {
            #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .cancelled)
            #expect(try Data(contentsOf: file) == originalBytes)
        } else {
            #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
            try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
            let committed = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
            let ref = try #require(committed.heightRegions.first)
            let payload = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
            #expect(payload.pages.first?.samples[10 * 64 + 10] == 4)
            if change == 3 {
                #expect(storage.height(atSample: .init(x: 10, z: 10)) == 8)
                owner.components[Terrain3DSave.self] = .init(storage: storage)
                await finishSave(app, owner: owner)
                #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
                let latest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
                let latestRef = try #require(latest.heightRegions.first)
                let latestPayload = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(latestRef.fileName).path)
                #expect(latestPayload.pages.first?.samples[10 * 64 + 10] == 8)
            }
        }
    }

    @Test("Saving immediately after a low-level write fails busy and does not block its mesh and native collision publication")
    func saveRequiresPublishedSamples() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let original = try Data(contentsOf: file)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let before = try buffers(owner)
        try storage.setHeight(8, at: .init(x: 10, z: 10))
        let gate = TerrainSavePauseGate()
        defer { Task { await gate.resume() } }
        owner.components[Terrain3DSave.self] = .init(storage: storage, onProgress: { _, _ in await gate.pause() })
        await app.main.runScheduler(.preUpdate)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .failed)
        await settle(app)
        #expect(try buffers(owner) != before)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [-22, 20, -22], to: [-22, -20, -22], radius: 0.01)
        #expect(fraction > 0.28 && fraction < 0.31)
        #expect(try Data(contentsOf: file) == original)
        #expect(await gate.paused == false)
        await gate.resume()
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Camera and physical-interest movement can stream regions while an immutable save continues", arguments: [false, true])
    func savesWhileInterestMoves(physicalInterest: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await largeSaveFixture(in: directory)
        let app = try await makeApp(physics: physicalInterest)
        let owner = app.main.spawn("Terrain") {
            Transform()
            Terrain3DSource(source: file.path, generatesCollision: physicalInterest, maximumResidentHeightBytes: 49_152, maximumLOD: 0, streamingRadius: 20, maximumTileUpdatesPerFrame: 64)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        let body = app.main.spawn("Moving interest") { Transform(position: [10, 20, 10]) }
        if physicalInterest {
            body.components[PhysicsBody3DComponent.self] = .init(shapes: [.generateSphere(radius: 0.5)], mass: 1, mode: .dynamic)
        }
        await settle(app)
        if physicalInterest { await app.main.runScheduler(.physicsSync) }
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(4, at: .init(x: 10, z: 10))
        await settle(app)
        let revision = storage.revision
        let gate = TerrainSavePauseGate()
        defer { Task { await gate.resume() } }
        owner.components[Terrain3DSave.self] = .init(storage: storage, onProgress: { _, _ in await gate.pause() })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline, !(await gate.paused) {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.paused)
        if physicalInterest {
            body.components[PhysicsBody3DComponent.self]?.setTransform(position: [1_034, 20, 10])
        } else {
            camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 1_034, z: 10)) == 1)
        await gate.resume()
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        #expect(owner.components[Terrain3DSaveStatus.self]?.savedRevision == revision)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 0 })
        let payload = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(payload.pages.first?.samples[10 * 64 + 10] == 4)
    }

    @Test("Undo to an original nonzero height remains dirty when its region is evicted before an older save commits")
    func retainsUndoAcrossSaveAndEviction() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await largeSaveFixture(in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 32_768, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(4, at: .init(x: 10, z: 10))
        await settle(app)
        let gate = TerrainSavePauseGate()
        defer { Task { await gate.resume() } }
        owner.components[Terrain3DSave.self] = .init(storage: storage, onProgress: { _, _ in await gate.pause() })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline, !(await gate.paused) {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.paused)
        try storage.setHeight(1, at: .init(x: 10, z: 10))
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == nil)
        await gate.resume()
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        camera.components[Transform.self] = Transform(position: [10, 20, 10])
        await settle(app)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        let manifest = try await AssetsManager.loadFresh(TerrainManifestAsset.self, at: file.path)
        let ref = try #require(manifest.heightRegions.first { $0.x == 0 })
        let payload = try await AssetsManager.loadFresh(TerrainRegionAsset.self, at: directory.appendingPathComponent(ref.fileName).path)
        #expect(payload.pages.first?.samples[10 * 64 + 10] == 1)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("A save waiting behind two paused writes does not stop the third source from streaming")
    func queuedSaveDoesNotFreezeResidency() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = try await makeApp()
        var owners: [Entity] = []
        for index in 0..<3 {
            let subdirectory = directory.appendingPathComponent("Source-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: subdirectory, withIntermediateDirectories: true)
            let file = try await largeSaveFixture(in: subdirectory)
            owners.append(
                app.main.spawn("Terrain \(index)") {
                    Transform()
                    Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 32_768, maximumLOD: 0, streamingRadius: 20, maximumTileUpdatesPerFrame: 64)
                }
            )
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storages = try owners.map { try #require($0.components[Terrain3DSourceSurface.self]?.storage) }
        for storage in storages { try storage.setHeight(4, at: .init(x: 10, z: 10)) }
        await settle(app)
        let gates = [TerrainSavePauseGate(), TerrainSavePauseGate(), TerrainSavePauseGate()]
        defer { Task { for gate in gates { await gate.resume() } } }
        for index in owners.indices {
            let gate = gates[index]
            owners[index].components[Terrain3DSave.self] = .init(storage: storages[index], onProgress: { _, _ in await gate.pause() })
        }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if await gates[0].paused, await gates[1].paused { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gates[0].paused)
        try #require(await gates[1].paused)
        #expect(await gates[2].paused == false)
        #expect(owners[2].components[Terrain3DSaveStatus.self]?.phase == .pending)
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(owners[2].components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storages[2].height(atSample: .init(x: 1_034, z: 10)) == 1)
        #expect(owners[2].components[Terrain3DSaveStatus.self]?.phase == .failed)
        #expect(await gates[2].paused == false)
        for gate in gates { await gate.resume() }
        await finishSave(app, owner: owners[0])
        await finishSave(app, owner: owners[1])
        #expect(owners[0].components[Terrain3DSaveStatus.self]?.phase == .saved)
        #expect(owners[1].components[Terrain3DSaveStatus.self]?.phase == .saved)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("In-flight save data remains pinned within one page and releases after saving the later Undo")
    func saveTransactionRespectsOnePageBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await largeSaveFixture(in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 16_384, maximumLOD: 0, streamingRadius: 20)
        }
        let camera = app.main.spawn("Camera") {
            Transform(position: [10, 20, 10]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        try storage.setHeight(4, at: .init(x: 10, z: 10))
        await settle(app)
        let gate = TerrainSavePauseGate()
        defer { Task { await gate.resume() } }
        owner.components[Terrain3DSave.self] = .init(storage: storage, onProgress: { _, _ in await gate.pause() })
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(3))
        while clock.now < deadline, !(await gate.paused) {
            await app.main.runScheduler(.preUpdate)
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.paused)
        try storage.setHeight(1, at: .init(x: 10, z: 10))
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        #expect(storage.height(atSample: .init(x: 1_034, z: 10)) == nil)
        await gate.resume()
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        try #require(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        camera.components[Transform.self] = Transform(position: [10, 20, 10])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        camera.components[Transform.self] = Transform(position: [1_034, 20, 10])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 1_034, z: 10)) == 1)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == nil)
    }
}
