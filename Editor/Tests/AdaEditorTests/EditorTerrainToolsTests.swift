@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaRender
@testable import AdaScene
import Foundation
import Testing

@testable import AdaEditor

@MainActor
@Suite("Terrain editor tools", .serialized)
struct EditorTerrainToolsTests {
    @Test("Five-octave height generation is deterministic, seeded and spatially varied")
    func noise() {
        let first = EditorTerrainNoise(seed: 42, amplitude: 12, frequency: 0.035)
        let second = EditorTerrainNoise(seed: 43, amplitude: 12, frequency: 0.035)
        let values = (0..<32).map { first.height(x: Float($0), z: 4) }
        #expect(values == (0..<32).map { first.height(x: Float($0), z: 4) })
        #expect(Set(values).count > 20)
        #expect(values != (0..<32).map { second.height(x: Float($0), z: 4) })
        #expect(values.allSatisfy { $0.isFinite && abs($0) <= 12 })
        #expect(EditorTerrainNoise(seed: 42, amplitude: 0, frequency: 0.035).height(x: 3, z: 7) == 0)
    }

    @Test("All 24 brush presets use real operation or shape settings")
    func presets() {
        #expect(EditorTerrainBrushPreset.all.count == 24)
        #expect(Set(EditorTerrainBrushPreset.all.map(\.name)).count == 24)
        #expect(Set(EditorTerrainBrushPreset.all.map(\.operation)).count == TerrainHeightBrushOperation.allCases.count)
    }

    @Test("Automatic rules preserve custom layers and variation toggles preserve existing rule roles")
    func automaticMaterials() {
        let own = TerrainMaterialPalette(layers: [.init(id: 17, name: "Custom texture", albedoPath: "custom.png")], fallbackLayerID: 17)
        let automatic = EditorTerrainAutoPalette.make(existing: own, variation: .init(isEnabled: true), addRules: true)
        #expect(automatic.layers.first?.id == 17)
        #expect(automatic.layers.first?.albedoPath == "custom.png")
        #expect(automatic.layers.count == 4)
        #expect(automatic.rules.count == 3)
        let toggled = EditorTerrainAutoPalette.make(existing: automatic, variation: .init(isEnabled: false), addRules: false)
        #expect(toggled.layers.map(\.id) == automatic.layers.map(\.id))
        #expect(toggled.rules == automatic.rules)
        #expect(toggled.layers.allSatisfy { !$0.variation.isEnabled })
    }

    @Test("Volume material rows use actual vertex height and independent triangle field coordinates")
    func volumeMaterials() throws {
        let storage = try TerrainHeightStorage(importing: Terrain3D(resolution: 65, size: 64))
        let palette = TerrainMaterialPalette(
            layers: [.init(id: 0, name: "Low"), .init(id: 1, name: "High")],
            fallbackLayerID: 0,
            rules: [.init(layerID: 1, height: .init(minimum: 5, maximum: 30))]
        )
        var descriptor = MeshDescriptor(name: "Stacked strata")
        descriptor.positions = MeshBuffer([Vector3(0, 0, 0), [1, 0, 0], [0, 0, 1], [0, 10, 0], [1, 10, 0], [0, 10, 1]])
        descriptor.normals = MeshBuffer([Vector3](repeating: .up, count: 6))
        descriptor.indicies = [0, 2, 1, 3, 5, 4]
        let field = try TerrainSourceMaterials.prepareVolume(descriptor, storage: storage, resolver: TerrainMaterialResolver(palette))
        let ids = try #require(field.descriptor[TerrainSourceMaterials.layerIDs]).elements
        let uv = try #require(field.descriptor[MeshDescriptor.textureCoordinates1]).elements
        #expect(field.evaluations == 6)
        #expect(uv.count == 6)
        #expect(ids[0].x == 0)
        #expect(ids[2].x == 1)
        #expect(field.descriptor.positions.elements[0].y == 0)
        #expect(field.descriptor.positions.elements[3].y == 10)
    }
}
