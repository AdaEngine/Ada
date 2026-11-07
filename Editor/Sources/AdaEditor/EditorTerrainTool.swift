@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorTerrainTool: String, CaseIterable {
    case sculpt = "Sculpt terrain"
    case paint = "Paint material"
    case erasePaint = "Erase material paint"
    case scatter = "Paint meshes"
    case eraseMeshes = "Erase meshes"
    case add = "Add solid"
    case subtract = "Subtract solid"
}

struct EditorTerrainBrushPreset {
    let name: String
    let operation: TerrainHeightBrushOperation
    let shape: TerrainBrushShape
    let radius: Float
    let strength: Float
    var step: Float = 1

    static let all: [Self] = [
        .init(name: "Soft hill", operation: .raise, shape: .softRound, radius: 8, strength: 3),
        .init(name: "Small hill", operation: .raise, shape: .softRound, radius: 3, strength: 2),
        .init(name: "Mountain", operation: .raise, shape: .softRound, radius: 16, strength: 10),
        .init(name: "Hard mound", operation: .raise, shape: .hardRound, radius: 5, strength: 4),
        .init(name: "Square mound", operation: .raise, shape: .square, radius: 6, strength: 4),
        .init(name: "Rock ridge", operation: .raise, shape: .ridge, radius: 8, strength: 6),
        .init(name: "Soft valley", operation: .lower, shape: .softRound, radius: 8, strength: 4),
        .init(name: "Deep valley", operation: .lower, shape: .softRound, radius: 12, strength: 10),
        .init(name: "Round pit", operation: .lower, shape: .hardRound, radius: 4, strength: 4),
        .init(name: "Square pit", operation: .lower, shape: .square, radius: 5, strength: 4),
        .init(name: "Narrow trench", operation: .lower, shape: .ridge, radius: 5, strength: 5),
        .init(name: "Crater", operation: .raise, shape: .crater, radius: 10, strength: 4),
        .init(name: "Gentle smooth", operation: .smooth, shape: .softRound, radius: 6, strength: 2),
        .init(name: "Strong smooth", operation: .smooth, shape: .hardRound, radius: 10, strength: 10),
        .init(name: "Round plateau", operation: .flatten, shape: .softRound, radius: 8, strength: 6),
        .init(name: "Square plateau", operation: .flatten, shape: .square, radius: 8, strength: 6),
        .init(name: "Set elevation", operation: .setHeight, shape: .hardRound, radius: 5, strength: 1),
        .init(name: "Ramp", operation: .ramp, shape: .softRound, radius: 5, strength: 1),
        .init(name: "Fine terraces", operation: .terrace, shape: .softRound, radius: 8, strength: 1, step: 0.5),
        .init(name: "Broad terraces", operation: .terrace, shape: .hardRound, radius: 12, strength: 1, step: 2),
        .init(name: "Fine noise", operation: .noise, shape: .softRound, radius: 6, strength: 0.5),
        .init(name: "Rock noise", operation: .noise, shape: .ridgedNoise, radius: 10, strength: 2),
        .init(name: "Gentle erosion", operation: .talus, shape: .softRound, radius: 8, strength: 1),
        .init(name: "Rock erosion", operation: .talus, shape: .hardRound, radius: 12, strength: 6),
    ]
}

enum EditorTerrainStrokeCommand: Sendable {
    case height(TerrainHeightBrushStroke)
    case surface(TerrainSurfaceBrushStroke)
    case instances(TerrainInstanceBrushStroke)
    case volume(TerrainVolumeOperation)
    case materials(TerrainMaterialPalette)
    case mesh(URL)
    case texture(URL, layerID: UInt16)
    case region(TerrainRegionCoordinate)
    case generate(EditorTerrainNoise)

    var changesResource: Bool {
        switch self {
        case .height, .surface, .instances: false
        case .volume, .materials, .mesh, .texture, .region, .generate: true
        }
    }
}

@MainActor
struct EditorTerrainSourceActions {
    let create: () -> Void
    let materials: () -> Void
    let variation: () -> Void
    let mesh: () -> Void
    let texture: () -> Void
    let extend: () -> Void
    let generate: () -> Void
    var join: (() -> Void)? = nil
    var detach: (() -> Void)? = nil
    var cancel: (() -> Void)? = nil
}
