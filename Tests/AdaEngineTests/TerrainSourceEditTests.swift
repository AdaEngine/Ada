@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("A staged height edit publishes query, mesh and collision together and its inverse delta restores the surface")
    func atomicHeightEditAndUndo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Editable terrain") {
            Transform()
            Terrain3DSource(source: file.path, streamingRadius: nil, maximumTileUpdatesPerFrame: 1)
        }
        await settle(app)
        await app.main.runScheduler(.physicsSync)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let original = try buffers(owner)
        let physics = try #require(app.main.physicsWorld3D)
        let point = TerrainGridPoint(x: 64, z: 64)
        let edit = Terrain3DHeightEdit(storage: storage, updates: [.init(point: point, height: 5)])
        owner.components[Terrain3DHeightEdit.self] = edit
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        var observedPreparation = false
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied { break }
            #expect(storage.height(atSample: point) == 0)
            #expect(try buffers(owner) == original)
            await app.main.runScheduler(.physicsSync)
            let fraction = physics.sphereCastFraction(from: [64, 10, 64], to: [64, -10, 64], radius: 0.01)
            #expect(fraction > 0.49 && fraction < 0.51)
            observedPreparation = observedPreparation || (owner.components[Terrain3DSourceStatus.self]?.preparedTileCount ?? 0) > 0
            if owner.components[Terrain3DSourceStatus.self]?.isPreparing != true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observedPreparation)
        let result = try #require(owner.components[Terrain3DHeightEditStatus.self])
        #expect(result.id == edit.id && result.phase == .applied && result.error == nil)
        let delta = try #require(result.delta)
        #expect(delta.changes.count == 1)
        #expect(delta.changes.first?.previousHeight == 0 && delta.changes.first?.height == 5)
        #expect(storage.height(atSample: point) == 5)
        #expect(owner.components[Terrain3DSourceSurface.self]?.storage === storage)
        let changed = try buffers(owner)
        for coordinate in original.keys {
            if coordinate.x < 2 && coordinate.z < 2 { #expect(changed[coordinate] != original[coordinate]) } else { #expect(changed[coordinate] == original[coordinate]) }
        }
        await app.main.runScheduler(.physicsSync)
        let raised = physics.sphereCastFraction(from: [64, 10, 64], to: [64, -10, 64], radius: 0.01)
        #expect(raised > 0.24 && raised < 0.26)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        #expect(storage.height(atSample: point) == 0)
        await app.main.runScheduler(.physicsSync)
        let restored = physics.sphereCastFraction(from: [64, 10, 64], to: [64, -10, 64], radius: 0.01)
        #expect(restored > 0.49 && restored < 0.51)
    }

    @Test("Invalid height edits preserve every live sample and working source state", arguments: ["budget", "nonfinite", "stale"])
    func invalidHeightEditsAreAtomic(reason: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        try authored.setHeight(1, at: .init(x: 10, z: 10))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(
            source: file.path,
            generatesCollision: false,
            maximumResidentHeightBytes: reason == "budget" ? 64 * 64 * 4 : 64 * 1_024 * 1_024
        )
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let edit = Terrain3DHeightEdit(
            storage: storage,
            updates: [
                .init(point: .init(x: 10, z: 10), height: 2),
                .init(point: .init(x: 70, z: 10), height: reason == "nonfinite" ? .nan : 3),
            ]
        )
        if reason == "stale" {
            try storage.setHeight(4, at: .init(x: 20, z: 10))
            await settle(app)
        }
        let original = try buffers(owner)
        let revision = storage.revision
        owner.components[Terrain3DHeightEdit.self] = edit
        await settle(app)
        let result = try #require(owner.components[Terrain3DHeightEditStatus.self])
        #expect(result.id == edit.id && result.phase == .failed)
        #expect(result.error != nil && result.delta == nil)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        #expect(storage.height(atSample: .init(x: 70, z: 10)) == 0)
        #expect(storage.revision == revision)
        #expect(try buffers(owner) == original)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(owner.components[Terrain3DSourceStatus.self]?.error == nil)
    }

    @Test("Removing a pending height request cancels all prepared tiles without changing the live generation")
    func cancelPendingHeightEdit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, maximumTileUpdatesPerFrame: 1)
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let original = try buffers(owner)
        let updates = storage.tileCoordinates.map { TerrainHeightUpdate(point: .init(x: $0.x * 64 + 10, z: $0.z * 64 + 10), height: 2) }
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: updates)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if (owner.components[Terrain3DSourceStatus.self]?.preparedTileCount ?? 0) > 0 { break }
            if owner.components[Terrain3DSourceStatus.self]?.isPreparing != true { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .pending)
        owner.components.remove(Terrain3DHeightEdit.self)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .cancelled)
        #expect(updates.allSatisfy { storage.height(atSample: $0.point) == 0 })
        #expect(try buffers(owner) == original)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Ready terrain generations expose their current native collision without requiring a later physics tick")
    func readyGenerationHasImmediateNativeCollision() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Immediately queryable terrain") {
            Transform(); Terrain3DSource(source: file.path)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let physics = try #require(app.main.physicsWorld3D)
        let initial = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01)
        #expect(initial > 0.49 && initial < 0.51)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: [.init(point: .init(x: 32, z: 32), height: 3)])
        await settle(app)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        #expect(storage.height(atSample: .init(x: 32, z: 32)) == 3)
        let raised = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01)
        #expect(raised > 0.34 && raised < 0.36)
        let delta = try #require(owner.components[Terrain3DHeightEditStatus.self]?.delta)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
        await settle(app)
        let restored = physics.sphereCastFraction(from: [0, 10, 0], to: [0, -10, 0], radius: 0.01)
        #expect(restored > 0.49 && restored < 0.51)
    }

    @Test("An atomic height edit can free one page and allocate another within the same resident budget, including Undo")
    func heightEditExchangesPagesWithinBudget() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        try authored.setHeight(1, at: .init(x: 10, z: 10))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, maximumResidentHeightBytes: 64 * 64 * 4)
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        owner.components[Terrain3DHeightEdit.self] = .init(
            storage: storage,
            updates: [
                .init(point: .init(x: 70, z: 10), height: 4),
                .init(point: .init(x: 10, z: 10), height: 0),
            ]
        )
        await settle(app)
        let status = try #require(owner.components[Terrain3DHeightEditStatus.self])
        #expect(status.phase == .applied)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 0)
        #expect(storage.height(atSample: .init(x: 70, z: 10)) == 4)
        #expect(storage.residentHeightBytes == 64 * 64 * 4)
        #expect(storage.revision == revision + 1)
        let delta = try #require(status.delta)
        #expect(delta.changes.count == 2)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        #expect(storage.height(atSample: .init(x: 70, z: 10)) == 0)
        #expect(storage.residentHeightBytes == 64 * 64 * 4)
    }

    @Test("Empty and unchanged height requests complete without allocating data revisions or replacing mesh buffers", arguments: [false, true])
    func unchangedHeightEditRetainsBuffers(empty: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Editable terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        let original = try buffers(owner)
        let updates: [TerrainHeightUpdate] = empty ? [] : [.init(point: .init(x: 10, z: 10), height: 0)]
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: updates)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.delta?.changes.isEmpty == true)
        #expect(storage.revision == revision)
        #expect(storage.residentHeightBytes == 0)
        #expect(try buffers(owner) == original)
    }

    @Test("Duplicate, absent, excessive and foreign-surface requests fail without poisoning a working terrain", arguments: ["duplicate", "missing", "tooMany", "foreign"])
    func rejectsInvalidHeightEditAddresses(reason: String) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Editable terrain") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        let original = try buffers(owner)
        let value = TerrainHeightUpdate(point: .init(x: 10, z: 10), height: 2)
        let updates: [TerrainHeightUpdate]
        switch reason {
        case "duplicate": updates = [value, value]
        case "missing": updates = [value, .init(point: .init(x: 1_000, z: 1_000), height: 3)]
        case "tooMany": updates = Array(repeating: value, count: Terrain3DHeightEdit.maximumUpdates + 1)
        default: updates = [value]
        }
        let target = reason == "foreign" ? try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64)) : storage
        owner.components[Terrain3DHeightEdit.self] = .init(storage: target, updates: updates)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.error != nil)
        #expect(storage.height(atSample: value.point) == 0)
        #expect(storage.revision == revision)
        #expect(try buffers(owner) == original)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }

    @Test("A replacement height request supersedes prepared work without publishing samples from the cancelled request")
    func supersedesPendingHeightEdit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, maximumTileUpdatesPerFrame: 1)
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let firstUpdates = storage.tileCoordinates.map { TerrainHeightUpdate(point: .init(x: $0.x * 64 + 10, z: $0.z * 64 + 10), height: 2) }
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: firstUpdates)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if (owner.components[Terrain3DSourceStatus.self]?.preparedTileCount ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        let replacement = Terrain3DHeightEdit(storage: storage, updates: [.init(point: .init(x: 10, z: 10), height: 7)])
        owner.components[Terrain3DHeightEdit.self] = replacement
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.id == replacement.id)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 7)
        #expect(firstUpdates.dropFirst().allSatisfy { storage.height(atSample: $0.point) == 0 })
    }

    @Test("A direct live write invalidates an already prepared height edit and only that live write reaches publication")
    func liveWriteRejectsPreparedHeightEdit() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let source = Terrain3DSource(source: file.path, generatesCollision: false, maximumTileUpdatesPerFrame: 1)
        let owner = app.main.spawn("Editable terrain") {
            Transform(); source
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let updates = storage.tileCoordinates.map { TerrainHeightUpdate(point: .init(x: $0.x * 64 + 10, z: $0.z * 64 + 10), height: 2) }
        let edit = Terrain3DHeightEdit(storage: storage, updates: updates)
        owner.components[Terrain3DHeightEdit.self] = edit
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(15))
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if (owner.components[Terrain3DSourceStatus.self]?.preparedTileCount ?? 0) > 0 { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try storage.setHeight(9, at: .init(x: 20, z: 10))
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.id == edit.id)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.error != nil)
        #expect(updates.allSatisfy { storage.height(atSample: $0.point) == 0 })
        #expect(storage.height(atSample: .init(x: 20, z: 10)) == 9)
        #expect(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
    }
}
