@_spi(AdaEngine) import AdaEngine
import Foundation
import Yams

/// The paintable, palette-based form of a .tilemap asset.
struct EditorTileMapResource: Codable, Equatable {
    struct PaletteLayer: Codable, Equatable {
        var name: String
        var zIndex: Int
        var isEnabled: Bool
        var cells: [[Int]]
        var cellOcclusion: [TileMapCellOcclusion]?
    }

    var atlasColors: [Color]
    var atlasTextures: [String]? = nil
    var tileSetReference: String? = nil
    var tileSetTiles: [TileMapSourceTile]? = nil
    /// Cells in older single-layer maps. New layered maps keep this empty.
    var cells: [[Int]]
    /// Palette-indexed layers, distinct from the engine's source-ID-based `layers` format.
    var paletteLayers: [PaletteLayer]? = nil
    var cellOcclusion: [TileMapCellOcclusion]?

    var effectiveLayers: [PaletteLayer] {
        if let paletteLayers, !paletteLayers.isEmpty { return paletteLayers }
        return [PaletteLayer(name: "Layer 1", zIndex: 0, isEnabled: true, cells: cells, cellOcclusion: cellOcclusion)]
    }

    var cellCount: Int { effectiveLayers.reduce(0) { $0 + $1.cells.count } }

    var allCells: [[Int]] { effectiveLayers.flatMap(\.cells) }

    static func read(from url: URL) throws -> Self {
        try YAMLDecoder().decode(Self.self, from: String(contentsOf: url, encoding: .utf8))
    }

    func write(to url: URL) throws {
        try Data(YAMLEncoder().encode(self).utf8).write(to: url, options: .atomic)
    }

    var componentPayload: EditorComponentPayload {
        var payload: EditorComponentPayload = [
            "atlasColors": .array(atlasColors.map { color in
                .object([
                    "red": .double(Double(color.red)),
                    "green": .double(Double(color.green)),
                    "blue": .double(Double(color.blue)),
                    "alpha": .double(Double(color.alpha)),
                ])
            }),
            "cells": .array(cells.map { .array($0.map(EditorSceneValue.int)) }),
        ]
        func encodedOcclusion(_ records: [TileMapCellOcclusion]) -> EditorSceneValue {
            .array(records.map { record in
                var value: [String: EditorSceneValue] = ["mode": .string(record.occlusion.mode.rawValue)]
                if let points = record.occlusion.points {
                    value["points"] = .array(points.map { .object(["x": .double(Double($0.x)), "y": .double(Double($0.y))]) })
                }
                if let size = record.occlusion.referenceSize {
                    value["referenceSize"] = .object(["width": .double(Double(size.width)), "height": .double(Double(size.height))])
                }
                return .object([
                    "position": .object(["x": .int(record.position.x), "y": .int(record.position.y)]),
                    "occlusion": .object(value),
                ])
            })
        }
        if let cellOcclusion { payload["cellOcclusion"] = encodedOcclusion(cellOcclusion) }
        if let paletteLayers {
            payload["paletteLayers"] = .array(paletteLayers.map { layer in
                var fields: [String: EditorSceneValue] = [
                    "name": .string(layer.name),
                    "zIndex": .int(layer.zIndex),
                    "isEnabled": .bool(layer.isEnabled),
                    "cells": .array(layer.cells.map { .array($0.map(EditorSceneValue.int)) }),
                ]
                if let records = layer.cellOcclusion { fields["cellOcclusion"] = encodedOcclusion(records) }
                return .object(fields)
            })
        }
        if let atlasTextures {
            payload["atlasTextures"] = .array(atlasTextures.map(EditorSceneValue.string))
        }
        if let tileSetReference {
            payload["tileSetReference"] = .string(tileSetReference)
        }
        if let tileSetTiles {
            payload["tileSetTiles"] = .array(tileSetTiles.map { tile in
                .object([
                    "sourceID": .int(tile.sourceID),
                    "atlasCoordinates": .array(tile.atlasCoordinates.map(EditorSceneValue.int)),
                ])
            })
        }
        return payload
    }
}

enum EditorTileMapReferenceError: LocalizedError {
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case let .invalid(reference): "Invalid tile map resource: \(reference)"
        }
    }
}

struct EditorTileSetPaletteTile {
    let reference: TileMapSourceTile
    let image: Image
    let sourceName: String
    var occlusion: TileOcclusionOverride?
}

enum EditorTileSetPalette {
    static func load(from tileSetURL: URL) throws -> [EditorTileSetPaletteTile] {
        let source = try String(contentsOf: tileSetURL, encoding: .utf8)
        guard let root = try Yams.load(yaml: source) as? [String: Any],
            let sources = root["sources"] as? [[String: Any]] else {
            throw EditorTileMapReferenceError.invalid(tileSetURL.path)
        }
        var palette: [EditorTileSetPaletteTile] = []
        for source in sources where source["type"] as? String == String(reflecting: TextureAtlasTileSource.self) {
            guard let data = source["data"] as? [String: Any],
                let sourceID = data["id"] as? Int,
                let imageData = data["image"],
                let tiles = data["tiles"] as? [[String: Any]] else { continue }
            let descriptor = try YAMLDecoder().decode(TileSourceImageDescriptor.self, from: Yams.dump(object: imageData))
            try descriptor.validate()
            let path = descriptor.resolvedPath(relativeTo: tileSetURL.deletingLastPathComponent())
            let imageURL = path.hasPrefix("file://") ? URL(string: path) : URL(fileURLWithPath: path)
            guard let imageURL else { throw EditorTileMapReferenceError.invalid(path) }
            let image = try Image(contentsOf: imageURL)
            for tile in tiles {
                guard let coordinates = tile["xy"] as? [Int], coordinates.count == 2 else { continue }
                let x = descriptor.margin.width + coordinates[0] * (descriptor.tileSize.width + descriptor.spacing.width)
                let y = descriptor.margin.height + coordinates[1] * (descriptor.tileSize.height + descriptor.spacing.height)
                guard x >= 0, y >= 0, x + descriptor.tileSize.width <= image.width,
                    y + descriptor.tileSize.height <= image.height else { continue }
                var sliced = Image(width: descriptor.tileSize.width, height: descriptor.tileSize.height)
                for row in 0..<descriptor.tileSize.height {
                    for column in 0..<descriptor.tileSize.width {
                        sliced.setPixel(in: [Float(column), Float(row)], color: image.getPixel(x: x + column, y: y + row))
                    }
                }
                let tileData = (tile["ad"] as? [String: Any])?["td"] as? [String: Any] ?? [:]
                var occlusion: TileOcclusionOverride?
                if let raw = tileData["occ"] {
                    let points = try YAMLDecoder().decode([Vector2].self, from: Yams.dump(object: raw))
                    let size = try tileData["occSize"].map { try YAMLDecoder().decode(Size.self, from: Yams.dump(object: $0)) }
                    occlusion = try .polygon(points, referenceSize: size)
                }
                palette.append(EditorTileSetPaletteTile(
                    reference: TileMapSourceTile(sourceID: sourceID, atlasCoordinates: coordinates),
                    image: sliced,
                    sourceName: data["name"] as? String ?? "Source \(sourceID)",
                    occlusion: occlusion
                ))
            }
        }
        return palette
    }
}
