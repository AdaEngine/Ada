import AdaAssets
import Foundation
import Testing

extension TerrainSurfaceAssetTests {
    @Test("Combined surface sections decode sliced Data without interpreting collection indices as offsets", arguments: ["height", "instances", "both"])
    func surfaceSlicedData(kind: String) throws {
        let instances = try kind == "height" ? [] : [TerrainRegionInstance(id: 99, prototypeID: 7, localPosition: [1, 2, 3])]
        let source = TerrainRegionAsset(
            x: -1,
            z: 1,
            tiles: kind == "instances" ? [] : [.init(x: 0, z: 0)],
            pages: [],
            instances: instances,
            surface: [.init(x: 0, z: 255, layerIDs: [7, 12, 0, 0], weights: [0.25, 0.75, 0, 0], overrideStrength: 0.625)],
            ruleMasks: [.init(x: 0, z: 255, maskID: 9, value: 0.125)]
        )
        let bytes = try source.encodedData()
        var prefixed = Data(repeating: 165, count: 37)
        prefixed.append(bytes)
        let slice = prefixed.dropFirst(37)
        try #require(slice.startIndex == 37)
        let loaded = try TerrainRegionAsset(data: slice)
        #expect(loaded.tiles == source.tiles && loaded.pages == source.pages && loaded.instances == instances)
        #expect(loaded.surface == source.surface && loaded.ruleMasks == source.ruleMasks)
        #expect(try loaded.encodedData() == bytes)
    }

    @Test("Surface validation rejects empty channels, duplicate layers, invalid proportions and positive-grid overflow")
    func surfaceTypedValidation() throws {
        func rejects(_ sample: TerrainRegionSurfaceSample, x: Int32 = 0) {
            let region = TerrainRegionAsset(x: x, z: 0, tiles: [], pages: [], surface: [sample])
            #expect(throws: (any Error).self) { try region.encodedData() }
        }
        rejects(.init(x: 0, z: 0))
        rejects(.init(x: 0, z: 0, layerIDs: [7, 7, 0, 0], weights: [0.5, 0.5, 0, 0], overrideStrength: 1))
        rejects(.init(x: 0, z: 0, layerIDs: [7, 0, 0, 0], weights: [0.5, 0, 0, 0], overrideStrength: 1))
        rejects(.init(x: 0, z: 0, tintStrength: .infinity))
        rejects(.init(x: 0, z: 0, roughness: .nan, roughnessStrength: 1))
        rejects(.init(x: 1, z: 0, tintStrength: 1), x: 4_096)
        let validBoundary = TerrainRegionAsset(
            x: 4_096,
            z: 0,
            tiles: [],
            pages: [],
            surface: [.init(x: 0, z: 0, tintStrength: 1)],
            ruleMasks: [.init(x: 0, z: 0, maskID: 1, value: 1)]
        )
        #expect(try TerrainRegionAsset(data: validBoundary.encodedData()).surface == validBoundary.surface)
    }
}
