import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Committed query snapshots follow staged sculpt and Undo, match transformed collision and survive unchanged native save")
    func surfaceQueryCommittedState() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try await surfaceQueryFixture(folder, resolution: 129)
        let app = try await makeApp(physics: true)
        let parentPose = Transform(position: [2, 0, 1])
        let pose = Transform(rotation: Quat(axis: [0, 1, 0], angle: 0.3), scale: [-2, 1.5, 3], position: [4, 3, -2])
        let parent = app.main.spawn("Environment") { parentPose }
        let owner = app.main.spawn("Hybrid terrain") { pose; Terrain3DSource(source: file.path, streamingRadius: nil, maximumTileUpdatesPerFrame: 1, queries: .init()) }
        parent.addChild(owner)
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let surface = try #require(owner.components[Terrain3DSourceSurface.self])
        let before = try #require(surface.queries)
        let far = TerrainTileCoordinate(x: 1, z: 1), originalFar = try #require(before.tileGeneration(at: far))
        func height(_ query: TerrainSurfaceQueries) throws -> Float {
            try #require(try query.raycast(.init(origin: [-54, 12, -54], direction: [0, -1, 0]))).position.y
        }
        #expect(abs(try height(before)) < 1e-5)
        let edit = Terrain3DHeightEdit(storage: surface.storage, updates: [.init(point: .init(x: 10, z: 10), height: 8)])
        owner.components[Terrain3DHeightEdit.self] = edit
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(15))
        var observedOld = false
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied { break }
            let current = try #require(owner.components[Terrain3DSourceSurface.self]?.queries)
            #expect(current.revision == before.revision)
            #expect(abs(try height(current)) < 1e-5)
            observedOld = true
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(observedOld)
        let status = try #require(owner.components[Terrain3DHeightEditStatus.self])
        #expect(status.id == edit.id && status.phase == .applied)
        let delta = try #require(status.delta)
        let after = try #require(owner.components[Terrain3DSourceSurface.self]?.queries)
        #expect(abs(try height(after) - 8) < 1e-5 && after.revision == surface.storage.revision)
        #expect(after.tileGeneration(at: far) == originalFar)
        #expect(abs(try height(before)) < 1e-5, "Previously captured indices remain immutable after the source commits new data")
        await app.main.runScheduler(.physicsSync)
        let physics = try #require(app.main.physicsWorld3D), matrix = parentPose.matrix * pose.matrix
        let start = (matrix * Vector4([-54, 12, -54], 1)).xyz, end = (matrix * Vector4([-54, -4, -54], 1)).xyz
        let physical = physics.sphereCastFraction(from: start, to: end, radius: 0.01)
        #expect(abs(physical - (12 - (try height(after))) / 16) < 0.01)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: surface.storage, undoing: delta)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        let restored = try #require(owner.components[Terrain3DSourceSurface.self]?.queries)
        #expect(abs(try height(restored)) < 1e-5 && restored.tileGeneration(at: far) == originalFar)
        let generations = surface.storage.tileCoordinates.map { restored.tileGeneration(at: $0) }
        owner.components[Terrain3DSave.self] = .init(storage: surface.storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        await settle(app)
        let saved = try #require(owner.components[Terrain3DSourceSurface.self]?.queries)
        #expect(surface.storage.tileCoordinates.map { saved.tileGeneration(at: $0) } == generations)
    }
}
