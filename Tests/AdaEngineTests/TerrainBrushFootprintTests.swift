@_spi(Internal) @testable import AdaApp
import AdaEngine
@_spi(Internal) @testable import AdaRender
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Rotated square and alpha stamps retain their lobes beyond the unrotated radius", arguments: [false, true])
    func rotatedBrushSupport(alpha: Bool) async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try await save(Terrain3D(resolution: 65, size: 64), in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Rotated brush") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        var settings = TerrainHeightBrushSettings(operation: .raise, radius: 3, strength: 2)
        settings.shape = alpha ? .alpha(try TerrainBrushAlpha(width: 1, height: 1, values: [255])) : .square
        settings.falloff = 0
        settings.rotation = .pi / 4
        owner.components[Terrain3DHeightEdit.self] = .init(
            storage: storage,
            brush: .init(
                settings: settings,
                points: [
                    .init(position: [-22, 0, -22], time: 0), .init(position: [-22, 0, -22], time: 1),
                ]
            )
        )
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        let lobe = try #require(storage.height(atSample: .init(x: 14, z: 10)))
        #expect(abs(lobe - 2) < 0.0001)
        #expect(storage.height(atSample: .init(x: 14, z: 14)) == 0)
    }

    @Test("Slope masks use canonical one-sided derivatives at the outer edge of a planar patch")
    func outerEdgeSlopeMask() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var terrain = Terrain3D(resolution: 65, size: 64)
        for z in 0..<65 { for x in 0..<65 { terrain.heights[z * 65 + x] = Float(x) } }
        let file = try await save(terrain, in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Slope") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        var settings = TerrainHeightBrushSettings(operation: .raise, radius: 1.1, strength: 1)
        settings.shape = .hardRound
        settings.slopeRange = 40...50
        for x in [0, 32] {
            owner.components[Terrain3DHeightEdit.self] = .init(
                storage: storage,
                brush: .init(
                    settings: settings,
                    points: [
                        .init(position: [Float(x) - 32, Float(x), -22], time: 0), .init(position: [Float(x) - 32, Float(x), -22], time: 0.1),
                    ]
                )
            )
            await settle(app)
            let height = try #require(storage.height(atSample: .init(x: x, z: 10)))
            #expect(abs(height - Float(x) - 0.1) < 0.0001)
        }
    }

    @Test("Slope masks keep the same result when their neighboring region becomes a normal-only halo")
    func slopeMaskUsesStreamingHalo() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        try authored.allocateRegion(at: .init(x: 1, z: 0))
        for z in 0...256 { for x in 0...512 { try authored.setHeight(Float(x), at: .init(x: x, z: z)) } }
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil, maximumTileUpdatesPerFrame: 64)
        let owner = app.main.spawn("Streamed slope") {
            Transform(); source
        }
        app.main.spawn("Camera") {
            Transform(position: [128, 300, 128]); Camera()
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        var settings = TerrainHeightBrushSettings(operation: .raise, radius: 1.1, strength: 1)
        settings.shape = .hardRound
        settings.slopeRange = 40...50
        let stroke = TerrainHeightBrushStroke(
            settings: settings,
            points: [
                .init(position: [256, 256, 128], time: 0), .init(position: [256, 256, 128], time: 0.1),
            ]
        )
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, brush: stroke)
        await settle(app)
        let originalResult = try #require(storage.height(atSample: .init(x: 256, z: 128)))
        #expect(abs(originalResult - 256.1) < 0.0001)
        let delta = try #require(owner.components[Terrain3DHeightEditStatus.self]?.delta)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, updates: delta.reversedUpdates)
        await settle(app)
        source.streamingRadius = 1
        owner.components[Terrain3DSource.self] = source
        await settle(app)
        #expect(storage.height(atSample: .init(x: 257, z: 128)) == nil)
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, brush: stroke)
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .applied)
        let streamedResult = try #require(storage.height(atSample: .init(x: 256, z: 128)))
        #expect(abs(streamedResult - originalResult) < 0.0001)
    }

    @Test("Aggregate union scans in a long sparse brush stroke are bounded before mutation")
    func rejectsAggregateBrushWork() async throws {
        let directory = try directory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let authored = try TerrainHeightStorage()
        try authored.allocateRegion(at: .init(x: 0, z: 0))
        let file = try await save(authored, in: directory)
        let app = try await makeApp()
        let owner = app.main.spawn("Long brush") {
            Transform(); Terrain3DSource(source: file.path, generatesCollision: false, maximumLOD: 0, streamingRadius: nil, maximumTileUpdatesPerFrame: 64)
        }
        await settle(app)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        let revision = storage.revision
        let original = try buffers(owner)
        var settings = TerrainHeightBrushSettings(operation: .noise, radius: 0.6, strength: 1)
        settings.shape = .hardRound
        settings.spacing = 2
        var points: [TerrainBrushPoint] = []
        for row in 0..<12 {
            let z = Float(10 + row * 4)
            let start: Float = row.isMultiple(of: 2) ? 10 : 235
            let end: Float = row.isMultiple(of: 2) ? 235 : 10
            points.append(.init(position: [start, 0, z], time: Double(row * 2)))
            points.append(.init(position: [end, 0, z], time: Double(row * 2 + 1)))
        }
        owner.components[Terrain3DHeightEdit.self] = .init(storage: storage, brush: .init(settings: settings, points: points))
        await settle(app)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.phase == .failed)
        #expect(owner.components[Terrain3DHeightEditStatus.self]?.error != nil)
        #expect(storage.revision == revision)
        #expect(try buffers(owner) == original)
    }
}

extension TerrainSourceRuntimeTests {
    @Test("Decoded brush alphas preserve bounded dimensions and pixel-count invariants")
    func rejectsMalformedDecodedAlphas() throws {
        let invalid = [
            #"{"width":0,"height":1,"values":[]}"#,
            #"{"width":1025,"height":1,"values":[]}"#,
            #"{"width":1024,"height":1024,"values":[]}"#,
            #"{"width":2,"height":2,"values":[0,1,2]}"#,
            #"{"width":1,"height":1,"values":[0,1]}"#,
        ]
        for json in invalid {
            var rejected = false
            do { _ = try JSONDecoder().decode(TerrainBrushAlpha.self, from: Data(json.utf8)) } catch { rejected = true }
            #expect(rejected)
        }
        let alpha = try TerrainBrushAlpha(width: 2, height: 2, values: [0, 64, 128, 255])
        let decoded = try JSONDecoder().decode(TerrainBrushAlpha.self, from: JSONEncoder().encode(alpha))
        #expect(decoded == alpha)
    }
}
