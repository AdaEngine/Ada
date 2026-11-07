import AdaEngine
@_spi(Internal) @testable import AdaRender
@testable import AdaScene
import Foundation
import Testing

extension TerrainSourceRuntimeTests {
    @Test("Inner transition endpoints preserve exact canonical heights with fractional spacing far from origin")
    func volumeLiveIntegrityFractionalSeam() throws {
        var terrain = Terrain3D(resolution: 65, size: 6.4)
        for z in 0..<65 { for x in 0..<65 { terrain.heights[z * 65 + x] = Float(z) * 0.01 } }
        let original = try TerrainHeightStorage(importing: terrain)
        var regions: [TerrainRegionAsset] = []
        for coordinate in original.resourceCoordinates {
            if let region = try original.regionAsset(at: coordinate) { regions.append(region) }
        }
        let storage = try TerrainHeightStorage(regions: regions, spacing: 0.1, origin: [100_000, 100_000])
        let snapshot = try #require(storage.snapshot(of: .init(x: 0, z: 0)))
        let source = snapshot.meshDescriptor().positions.elements
        let expected = [source[32 * 65 + 1], source[33 * 65 + 1], source[32 * 65 + 2]]
        var positions = expected, normals = Array(repeating: Vector3(0, 1, 0), count: 3), indices: [UInt32] = [0, 1, 2]
        _ = try TerrainVolumeSeamGeometry.conform(
            positions: &positions,
            normals: &normals,
            indices: &indices,
            snapshot: snapshot,
            edges: .minX,
            maximumTriangles: 4_096
        )
        #expect(positions[0] == expected[0], "The inner ring must meet the original heightfield endpoint even when Float world increments are uneven")
        #expect(positions[1] == expected[1])
    }

    @Test("Unsupported volume palette input reaches a terminal state and retains a valid previously published surface")
    func volumeLiveIntegrityPaletteTerminal() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (file, baseline) = try await volumeIntegrityFixture(folder, palette: true, volume: false)
        let app = try await makeApp()
        var source = Terrain3DSource(source: file.path, streamingRadius: nil)
        let owner = app.main.spawn("Palette terrain") { Transform(); source }
        await settle(app)
        try #require(owner.components[Terrain3DSourceStatus.self]?.isReady == true)
        let previous = try buffers(owner)
        _ = try await AssetsManager.saveTerrainRegions(
            [],
            manifest: baseline,
            at: file.path,
            mode: .update(removing: []),
            volume: .init(document: .init(cellSize: 1, origin: [-32, 0, -32], operations: [volumeIntegrityOperation()]), bricks: [])
        )
        source.reloadGeneration += 1; owner.components[Terrain3DSource.self] = source
        let clock = ContinuousClock(), deadline = ContinuousClock().now.advanced(by: .seconds(4))
        var terminal: Terrain3DSourceStatus?
        while clock.now < deadline {
            await app.main.runScheduler(.preUpdate)
            if let status = owner.components[Terrain3DSourceStatus.self], !status.isPreparing, status.isReady || status.error != nil {
                terminal = status; break
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(terminal != nil, "The source must either publish supported material geometry or report a stable error rather than retry forever")
        if terminal?.isReady == false { #expect(try buffers(owner) == previous) }
    }

    @Test("Unchanged native save acknowledgment preserves prepared operands, density and tile generations")
    func volumeLiveIntegritySaveReuse() async throws {
        let folder = try directory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let (file, _) = try await volumeIntegrityFixture(folder)
        let app = try await makeApp()
        let owner = app.main.spawn("Volume save") { Transform(); Terrain3DSource(source: file.path, streamingRadius: nil) }
        await settle(app)
        let before = try #require(owner.components[TerrainSourceState.self]?.residency?.volume)
        let cacheIDs = Dictionary(uniqueKeysWithValues: before.cache.coordinates.map { ($0, before.cache.brickGeneration(at: $0)) })
        let tileIDs = before.tiles.mapValues(\.generation), meshIDs = try buffers(owner)
        let storage = try #require(owner.components[Terrain3DSourceSurface.self]?.storage)
        owner.components[Terrain3DSave.self] = .init(storage: storage)
        await finishSave(app, owner: owner)
        #expect(owner.components[Terrain3DSaveStatus.self]?.phase == .saved)
        await settle(app)
        let after = try #require(owner.components[TerrainSourceState.self]?.residency?.volume)
        #expect(after.tiles.mapValues(\.generation) == tileIDs, "A height-only save must retain the immutable volume worker products")
        #expect(Dictionary(uniqueKeysWithValues: after.cache.coordinates.map { ($0, after.cache.brickGeneration(at: $0)) }) == cacheIDs)
        #expect(try buffers(owner) == meshIDs)
    }

    private func volumeIntegrityOperation() -> TerrainVolumeOperation {
        .init(operation: .union, operand: .primitive(.sphere(radius: 2)), transform: .init(translation: [0, 4, 0]))
    }

    private func volumeIntegrityFixture(_ folder: URL, palette: Bool = false, volume: Bool = true) async throws -> (URL, TerrainManifestAsset) {
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        var regions: [TerrainRegionAsset] = []
        for coordinate in storage.resourceCoordinates {
            if let region = try storage.regionAsset(at: coordinate) { regions.append(region) }
        }
        let file = folder.appendingPathComponent("world.aterrain")
        let materials: TerrainMaterialPalette? = palette ? .init(layers: [.init(id: 7, name: "Rock")], fallbackLayerID: 7) : nil
        let request: TerrainVolumeSave? = volume ? .init(document: .init(cellSize: 1, origin: [-32, 0, -32], operations: [volumeIntegrityOperation()]), bricks: []) : nil
        let saved = try await AssetsManager.saveTerrainRegions(
            regions,
            manifest: .init(spacing: storage.spacing, originX: storage.origin.x, originZ: storage.origin.y, materials: materials),
            at: file.path,
            volume: request
        )
        return (file, saved)
    }
}
