import AdaAssets
@_spi(Internal) import AdaRender
@testable import AdaScene
import Math
import Testing

@Suite("Terrain surface canonical addresses")
struct TerrainSurfaceAddressTests {
    @Test("Paint and masks agree at negative and positive-grid boundary ownership", arguments: [false, true])
    func canonicalSurfaceCoordinates(positiveBoundary: Bool) throws {
        let leftX: Int32 = positiveBoundary ? 4_095 : -1
        let regionZ: Int32 = positiveBoundary ? 0 : -1
        let localZ: UInt8 = positiveBoundary ? 32 : 255
        let tileZ = positiveBoundary ? 0 : -1
        let edge = TerrainRegionSurfaceSample(x: 0, z: localZ, layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 0.25)
        let left = TerrainRegionAsset(
            x: leftX,
            z: regionZ,
            tiles: [.init(x: 3, z: positiveBoundary ? 0 : 3)],
            pages: [],
            surface: positiveBoundary ? [] : [.init(x: 255, z: 255, layerIDs: [12, 0, 0, 0], weights: [1, 0, 0, 0], overrideStrength: 1)]
        )
        let right = TerrainRegionAsset(
            x: leftX + 1,
            z: regionZ,
            tiles: positiveBoundary ? [] : [.init(x: 0, z: 3)],
            pages: [],
            surface: [edge],
            ruleMasks: [.init(x: 0, z: localZ, maskID: 9, value: 1)]
        )
        let storage = try TerrainHeightStorage(regions: [left, right])
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 7, name: "Base"), .init(id: 12, name: "Paint")],
            fallbackLayerID: 7,
            rules: [.init(layerID: 7), .init(layerID: 12, maskID: 9)]
        )
        let resolver = try TerrainMaterialResolver(palette)
        let tile = TerrainTileCoordinate(x: Int(leftX) * 4 + 3, z: tileZ)
        let snapshot = try #require(storage.snapshot(of: tile))
        let descriptor = try TerrainSourceMaterials.prepare(snapshot, storage: storage, resolver: resolver).descriptor
        let ids = try #require(descriptor[TerrainSourceMaterials.layerIDs]).elements
        let weights = try #require(descriptor[TerrainSourceMaterials.weights]).elements
        let row = Int(localZ % 64) * 65, at = row + 64
        #expect(ids[at].x == 12 && abs(weights[at].x - 0.625) < 0.0001)
        #expect(ids[at].y == 7 && abs(weights[at].y - 0.375) < 0.0001)
        if !positiveBoundary {
            #expect(ids[row + 63].x == 12 && weights[row + 63].x == 1)
            let next = try #require(storage.snapshot(of: .init(x: 0, z: -1)))
            let fields = try TerrainSourceMaterials.prepare(next, storage: storage, resolver: resolver).descriptor
            #expect(fields[TerrainSourceMaterials.layerIDs]?.elements[row] == ids[at])
            #expect(fields[TerrainSourceMaterials.weights]?.elements[row] == weights[at])
        }
        let point = TerrainGridPoint(x: Int(leftX + 1) * 256, z: Int(regionZ) * 256 + Int(localZ))
        #expect(storage.surfaceSnapshot().sample(at: point) == edge)
        #expect(storage.surfaceSnapshot().mask(at: point, id: 9) == 1)
    }
}
