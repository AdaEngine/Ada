@_spi(AdaEngine) import AdaEngine
import Foundation
import Yams

/// The paintable, palette-based form of a .tilemap asset.
struct EditorTileMapResource: Codable, Equatable {
    var atlasColors: [Color]
    var atlasTextures: [String]? = nil
    var tileSetReference: String? = nil
    var tileSetTiles: [TileMapSourceTile]? = nil
    var cells: [[Int]]

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
                palette.append(EditorTileSetPaletteTile(
                    reference: TileMapSourceTile(sourceID: sourceID, atlasCoordinates: coordinates),
                    image: sliced,
                    sourceName: data["name"] as? String ?? "Source \(sourceID)"
                ))
            }
        }
        return palette
    }
}
