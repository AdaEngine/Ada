@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Time-based raising publishes one native surface and its delta reverses the complete stroke")
    func raisesWithAtomicBrushAndUndo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp(physics: true)
        let owner = app.main.spawn("Brush terrain") {
            Transform(); Terrain3DSource(source: file.path, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let settings = TerrainHeightBrushSettings(operation: .raise, radius: 2, strength: 2)
        let stroke = TerrainHeightBrushStroke(
            settings: settings,
            points: [
                .init(position: [-22, 0, -22], time: 0), .init(position: [-22, 0, -22], time: 1),
            ]
        )
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, brush: stroke)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        let height = try #require(storage.height(atSample: .init(x: 10, z: 10)))
        #expect(abs(height - 2) < 0.0001)
        #expect(storage.height(atSample: .init(x: 13, z: 10)) == 0)
        let physics = try #require(app.main.physicsWorld3D)
        let fraction = physics.sphereCastFraction(from: [-22, 20, -22], to: [-22, -20, -22], radius: 0.01)
        #expect(fraction > 0.43 && fraction < 0.46)
        let delta = try #require(owner.components[Terrain3DHeightEditStatus.self]?.delta)
        #expect(!delta.changes.isEmpty)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
        await settle(app)
        #expect(storage.height(atSample: .init(x: 10, z: 10)) == 0)
    }

    @Test("Time-tool results are independent of collinear input event subdivision", arguments: [TerrainHeightBrushOperation.raise, .lower, .flatten])
    func brushTimeSamplingIsStable(operation: TerrainHeightBrushOperation) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights[10 * 65 + 10] = 4
        let file = try await save(terrain, in: directory)
        let app = try await makeApp()
        let owners = (0..<2).map { index in
            app.main.spawn("Brush \(index)") {
                Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
            }
        }
        await settle(app)
        let settings = TerrainHeightBrushSettings(operation: operation, radius: 3, strength: 2)
        let sparse = [TerrainBrushPoint(position: [-22, 4, -22], time: 0), .init(position: [-18, 0, -22], time: 1)]
        let dense = (0...20).map { i in TerrainBrushPoint(position: [-22 + Float(i) / 5, 4 - Float(i) / 5, -22], time: Double(i) / 20) }
        let storages = try owners.map { try #require($0.components[Terrain3DSourceSurface.self]?.storage) }
        for index in owners.indices {
            owners[index].components[Terrain3DHeightEdit.self] = .init(storage: storages[index], brush: .init(settings: settings, points: index == 0 ? sparse : dense))
        }
        await settle(app)
        for z in 7...13 {
            for x in 7...17 {
                let a = try #require(storages[0].height(atSample: .init(x: x, z: z)))
                let b = try #require(storages[1].height(atSample: .init(x: x, z: z)))
                #expect(abs(a - b) < 0.0001)
            }
        }
        let deltas = owners.compactMap { $0.components[Terrain3DHeightEditStatus.self]?.delta }
        #expect(deltas.count == 2 && deltas.allSatisfy { !$0.changes.isEmpty })
    }

    @Test("Stamp operations set height, build a ramp, terrace and generate repeatable seeded noise", arguments: [TerrainHeightBrushOperation.setHeight, .ramp, .terrace, .noise])
    func appliesHeightStampOperations(operation: TerrainHeightBrushOperation) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 65, size: 64)
        if operation == .terrace { terrain.heights = Array(repeating: 1.3, count: 65 * 65) }
        let file = try await save(terrain, in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Stamp") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        var settings = TerrainHeightBrushSettings(operation: operation, radius: 2, strength: 1)
        settings.targetHeight = 6
        settings.seed = 42
        let points: [TerrainBrushPoint] =
            operation == .ramp
            ? [.init(position: [-22, 0, -22], time: 0), .init(position: [-18, 4, -22], time: 1)]
            : [.init(position: [-22, 0, -22], time: 0)]
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: points))
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        switch operation {
        case .setHeight: #expect(storage.height(atSample: .init(x: 10, z: 10)) == 6)
        case .ramp:
            let height = try #require(storage.height(atSample: .init(x: 12, z: 10)))
            #expect(abs(height - 2) < 0.0001)
        case .terrace: #expect(storage.height(atSample: .init(x: 10, z: 10)) == 1)
        case .noise:
            let delta = try #require(owner.components[Terrain3DHeightEditStatus.self]?.delta)
            #expect(!delta.changes.isEmpty)
            #expect(delta.changes.allSatisfy { abs($0.height) <= 1 })
            owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
            await settle(app)
            owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: points))
            await settle(app)
            #expect(owner.components[Terrain3DHeightEditStatus.self]?.delta?.changes == delta.changes)
        default: Issue.record("Unexpected stamp operation")
        }
    }

    @Test("Smoothing converges and local talus relaxation conserves height without writing beyond its footprint", arguments: [TerrainHeightBrushOperation.smooth, .talus])
    func appliesLocalRelaxation(operation: TerrainHeightBrushOperation) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 65, size: 64)
        terrain.heights[10 * 65 + 10] = 8
        let file = try await save(terrain, in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Relax") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let settings = TerrainHeightBrushSettings(operation: operation, radius: 3, strength: 10)
        owner.components[Terrain3DHeightEdit.self] = .init(
            storage: storage,
            brush: .init(
                settings: settings,
                points: [
                    .init(position: [-22, 8, -22], time: 0), .init(position: [-22, 8, -22], time: 0.2),
                ]
            )
        )
        await settle(app)
        let delta = try #require(owner.components[Terrain3DHeightEditStatus.self]?.delta)
        #expect(!delta.changes.isEmpty)
        #expect(delta.changes.allSatisfy { $0.height >= 0 && $0.height <= 8 })
        #expect(try #require(storage.height(atSample: .init(x: 10, z: 10))) < 8)
        #expect(storage.height(atSample: .init(x: 14, z: 10)) == 0)
        if operation == .talus { #expect(abs(delta.changes.reduce(Float(0)) { $0 + $1.height - $1.previousHeight }) < 0.001) }
    }

    @Test("Invalid brush input and excessive work fail without changing data or visible buffers")
    func rejectsInvalidBrushesAtomically() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Invalid brush") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let original = try buffers(owner)
        let revision = storage.revision
        var invalid = TerrainHeightBrushSettings(operation: .raise)
        invalid.radius = .nan
        let giant = TerrainHeightBrushSettings(operation: .raise, radius: 10_000)
        for settings in [invalid, giant] {
            owner.components[Terrain3DHeightEdit.self] = .init(
                storage: storage,
                brush: .init(
                    settings: settings,
                    points: [
                        .init(position: [0, 0, 0], time: 0), .init(position: [0, 0, 0], time: 1),
                    ]
                )
            )
            await settle(app)
            #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .failed)
            #expect(owner.components[Terrain3DHeightEditStatus.self]?.error != nil)
            #expect(storage.revision == revision)
            #expect(try buffers(owner) == original)
        }
    }
}
