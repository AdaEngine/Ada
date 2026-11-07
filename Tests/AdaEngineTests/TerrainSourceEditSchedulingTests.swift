@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("The tile budget bounds actual native BVH creations on loading and editing, including the final publication frame")
    func nativeCookingRespectsFrameBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Budgeted collision") {
            Transform()
            Terrain3DSource(source: file.path, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        }
        let physics = try #require(app.main.physicsWorld3D)
        let metrics = physics.collisionPreparationMetrics
        func drain(expectedCooks: UInt64) async throws {
            let initial = metrics.snapshot.nativeTriangleMeshCount
            let clock = ContinuousClock()
            let deadline = clock.now.advanced(by: .seconds(15))
            while clock.now < deadline {
                let before = metrics.snapshot.nativeTriangleMeshCount
                await app.main.runScheduler(.preUpdate)
                let after = metrics.snapshot.nativeTriangleMeshCount
                #expect(after - before <= 1)
                if owner.components[Terrain3DSourceStatus.self]?.isReady == true, after == initial + expectedCooks { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
            #expect(metrics.snapshot.nativeTriangleMeshCount == initial + expectedCooks)
        }
        try await drain(expectedCooks: 16)
        #expect(metrics.snapshot.triangleCount > 0)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let updates = storage.tileCoordinates.map { TerrainHeightUpdate(point: .init(x: $0.x * 64 + 10, z: $0.z * 64 + 10), height: 2) }
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: updates)
        try await drain(expectedCooks: 16)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        let complete = metrics.snapshot.nativeTriangleMeshCount
        for _ in 0..<3 { await app.main.runScheduler(.physicsSync) }
        #expect(metrics.snapshot.nativeTriangleMeshCount == complete)
    }

    @Test("Cancelling a queued height request completes its status even before a worker slot is admitted")
    func cancelsHeightEditBeforeAdmission() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        let owners = (0..<3).map { index in
            app.main.spawn("Editable terrain \(index)") {
                Transform(); source
            }
        }
        await settle(app)
        for owner in owners.prefix(2) {
            let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
            let updates = storage.tileCoordinates.map { TerrainHeightUpdate(point: .init(x: $0.x * 64 + 10, z: $0.z * 64 + 10), height: 2) }
            owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: updates)
        }
        await app.main.runScheduler(.preUpdate)
        let queued = owners[2]
        let storage = try #require(queued.components[Terrain3DSourceSurface.self]?.storage)
        let original = try buffers(queued)
        let edit = Terrain3DHeightEdit(storage: storage, updates: [.init(point: .init(x: 10, z: 10), height: 5)])
        queued.components[Terrain3DHeightEdit.self] = edit
        await app.main.runScheduler(.preUpdate)
        #expect(queued.components[Terrain3DHeightEditStatus.self]?.phase == .pending)
        #expect(queued.components[Terrain3DSourceStatus.self]?.preparedTileCount == 0)
        queued.components.remove(Terrain3DHeightEdit.self)
        await settle(app)
        #expect(queued.components[Terrain3DHeightEditStatus.self]?.id == edit.id)
        #expect(queued.components[Terrain3DHeightEditStatus.self]?.phase == .cancelled)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 0)
        #expect(try buffers(queued) == original)
    }

    @Test("A failed edit cannot announce readiness for collision settings that have not been published")
    func failedEditDoesNotAnnounceUnpublishedCollision() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp(physics: true)
        var source = Terrain3DSource(source: file.path, generatesCollision: false)
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        source.generatesCollision = true
        owner.components[Terrain3DSource.self] = source
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: [.init(point: .init(x: 10, z: 10), height: .nan)])
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DHeightEditStatus.self]?.phase == .failed { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let physics = try #require(app.main.physicsWorld3D)
        if owner.components[Terrain3DSourceStatus.self]?.isReady == true {
            #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01) < 1)
        }
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01) < 1)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 0)
    }

    @Test("An edit cannot silently consume concurrent residency or memory settings", arguments: [false, true])
    func heightEditDoesNotConsumeUnpublishedResidency(rejectBudget: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        for x in [0, 20] { try authored.allocateRegion(at: .init(x: x, z: 0)) }
        try authored.setHeight(1, at: .init(x: 10, z: 10))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        var source = Terrain3DSource(
            source: file.path,
            generatesCollision: false,
            maximumResidentHeightBytes: 64 * 64 * 4,
            maximumResidentRegions: 2,
            streamingRadius: 128
        )
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        app.main.spawn("Camera") {
            Transform(position: [128, 0, 128]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let original = try buffers(owner)
        #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
        source.streamingRadius = 6_000
        if rejectBudget { source.maximumResidentHeightBytes = 0 }
        owner.components[Terrain3DSource.self] = source
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: [.init(point: .init(x: 10, z: 10), height: 2)])
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.error != nil)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        if rejectBudget {
            #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == false)
            #expect(owner.components[Terrain3DSourceStatus.self]?.error != nil)
            #expect(storage.memoryBudgetBytes == 64 * 64 * 4)
            #expect(storage.regionCoordinates == [.init(x: 0, z: 0)])
            #expect(try buffers(owner) == original)
        } else {
            #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
            #expect(storage.regionCoordinates == [0, 20].map { .init(x: $0, z: 0) })
        }
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Removing a source during height preparation clears its edit state and derived collision while retaining authored children")
    func removingSourceClearsHeightEditState() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp(physics: true)
        let source = Terrain3DSource(source: file.path, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        let prop = app.main.spawn("Authored prop") { Transform(position: [100, 0, 100]) }
        owner.addChild(prop)
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let updates = storage.tileCoordinates.map { TerrainHeightUpdate(point: .init(x: $0.x * 64 + 10, z: $0.z * 64 + 10), height: 2) }
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: updates)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if (owner.components[Terrain3DSourceStatus.self]?.preparedTileCount ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .pending)
        owner.components.remove(Terrain3DSource.self)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEdit.self] == nil)
        #expect(owner.components[Terrain3DHeightEditStatus.self] == nil)
        #expect(owner.components[Terrain3DSourceStatus.self] == nil)
        #expect(owner.components[Terrain3DSourceSurface.self] == nil)
        #expect(owner.children.map(\.id) == [prop.id])
        let physics = try #require(app.main.physicsWorld3D)
        #expect(physics.sphereCastFraction(from: [10, 10, 10], to: [10, -10, 10], radius: 0.01) == 1)
        #expect(updates.allSatisfy { storage.height(atSample: $0.point) == 0 })
    }
}
