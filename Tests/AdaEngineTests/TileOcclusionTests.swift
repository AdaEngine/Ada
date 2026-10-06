import AdaAssets
import AdaRender
@testable import AdaTilemap
import Foundation
import Math
import Testing

@Suite("Tile occlusion resources")
@MainActor
struct TileOcclusionTests {
    @Test("Simple polygons accept either winding and reject crossing/degenerate/nonfinite shapes")
    func polygonValidation() throws {
        let valid: [Vector2] = [[-1, -1], [1, -1], [1, 1], [-1, 1]]
        try TileOcclusionPolygon.validate(valid)
        try TileOcclusionPolygon.validate(valid.reversed())
        for points: [Vector2] in [
            [], [[0, 0], [1, 0]], [[0, 0], [1, 0], [2, 0]],
            [[-1, -1], [1, 1], [-1, 1], [1, -1]], [[0, 0], [1, 0], [0, .infinity]],
        ] {
            #expect(throws: TileOcclusionPolygon.ValidationError.self) { try TileOcclusionPolygon.validate(points) }
        }
    }

    @Test("Native cells round-trip exceptions and legacy cells inherit")
    func nativeCells() throws {
        let triangle = try TileOcclusionOverride.polygon([[0, 0], [1, 0], [0, 1]], referenceSize: [2, 2])
        for value in [TileOcclusionOverride.disabled, triangle] {
            let cell = TileMap.FileContent.Tile(position: [-1, 2], atlasPosition: [3, 4], sourceId: 5, orientation: .mirrorX, occlusion: value)
            let decoded = try JSONDecoder().decode(TileMap.FileContent.Tile.self, from: JSONEncoder().encode(cell))
            #expect(decoded.occlusion == value)
            #expect(decoded.orientation == .mirrorX)
        }
        let legacy = Data(#"{"p":[0,0],"ap":[0,0],"sid":0}"#.utf8)
        #expect(try JSONDecoder().decode(TileMap.FileContent.Tile.self, from: legacy).occlusion == nil)
    }

    @Test("Layered and legacy palette resources load per-cell exceptions through the asset loader")
    func paletteCells() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("TileOcclusion-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let header = "atlasColors: [{red: 1, green: 1, blue: 1, alpha: 1}]\n"
        for layered in [false, true] {
            let file = directory.appendingPathComponent("map-\(layered).tilemap")
            let disabled = "[{position: {x: -2, y: 3}, occlusion: {mode: disabled}}]"
            let body = layered
                ? "cells: []\npaletteLayers: [{name: Walls, zIndex: 0, isEnabled: true, cells: [[-2, 3, 0]], cellOcclusion: \(disabled)}]\n"
                : "cells: [[-2, 3, 0]]\ncellOcclusion: \(disabled)\n"
            try Data((header + body).utf8).write(to: file)
            let handle = try await AssetsManager.load(TileMap.self, at: file.path)
            let map = try #require(handle.asset)
            #expect(map.layers[0].getCellOcclusion(at: [-2, 3]) == .disabled)
        }
    }
}
