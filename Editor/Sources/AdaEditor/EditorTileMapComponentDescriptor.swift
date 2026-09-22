@_spi(AdaEngine) import AdaEngine

extension EditorComponentRegistry {
    static let tileMapDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.tileMap,
        displayName: "Tile Map",
        category: "2D",
        description: "Displays an editable tile map with a configurable tile size.",
        requiredComponentTypeNames: [
            EditorBuiltInComponentType.transform,
            String(reflecting: NoFrustumCulling.self),
        ],
        fields: [
            EditorComponentField(key: "tileDisplaySize", label: "Tile Size", kind: .vector2),
            EditorComponentField(key: "atlasColors", label: "Inline Atlas Colors", kind: .readOnly),
            EditorComponentField(key: "cells", label: "Inline Cells", kind: .readOnly),
        ],
        makeDefaultPayload: {
            [
                "tileDisplaySize": .array([.double(16), .double(16)]),
                "atlasColors": .array([]),
                "cells": .array([]),
            ]
        },
        decode: { payload in
            let size: Vector2
            if case let .array(values) = payload["tileDisplaySize"], values.count >= 2 {
                size = Vector2(
                    Float(values[0].doubleValue ?? 16),
                    Float(values[1].doubleValue ?? 16)
                )
            } else {
                size = Vector2(16, 16)
            }
            let tileMap = TileMap()
            if case let .array(colorValues) = payload["atlasColors"], !colorValues.isEmpty {
                var atlas = Image(width: colorValues.count, height: 1, color: .white)
                for (index, colorValue) in colorValues.enumerated() {
                    atlas.setPixel(in: [Float(index), 0], color: colorValue.colorValue ?? .white)
                }
                let source = TextureAtlasTileSource(from: atlas, size: [1, 1])
                source.name = "Inline scene atlas"
                for index in colorValues.indices {
                    source.createTile(for: [index, 0])
                }
                let sourceID = tileMap.tileSet.addTileSource(source)
                if case let .array(cells) = payload["cells"] {
                    for cell in cells {
                        guard case let .array(values) = cell, values.count >= 3 else {
                            continue
                        }
                        tileMap.layers[0].setCell(
                            at: [Int(values[0].doubleValue ?? 0), Int(values[1].doubleValue ?? 0)],
                            sourceId: sourceID,
                            atlasCoordinates: [Int(values[2].doubleValue ?? 0), 0]
                        )
                    }
                }
            }
            return TileMapComponent(
                tileMap: tileMap,
                tileDisplaySize: Size(width: size.x, height: size.y)
            )
        }
    )
}
