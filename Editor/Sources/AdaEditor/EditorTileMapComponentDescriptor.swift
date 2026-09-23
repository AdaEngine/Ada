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
            EditorComponentField(key: "map", label: "Map Resource", kind: .assetReference),
            EditorComponentField(key: "tileDisplaySize", label: "Tile Size", kind: .vector2),
        ],
        makeDefaultPayload: {
            [
                "map": .string(""),
                "tileDisplaySize": .array([.double(16), .double(16)]),
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
            var cells: [[Int]] = []
            if case let .array(values) = payload["cells"] {
                for value in values {
                    guard case let .array(coordinates) = value else { continue }
                    cells.append(coordinates.compactMap { $0.doubleValue.map(Int.init) })
                }
            }
            if case let .array(paths) = payload["atlasTextures"], !paths.isEmpty {
                var images = try paths.map { path -> Image in
                    guard case let .string(value) = path else {
                        throw EditorTileMapReferenceError.invalid("Missing tile texture path")
                    }
                    return try Image(contentsOf: URL(fileURLWithPath: value))
                }
                if let first = images.first, case let .array(colors) = payload["atlasColors"] {
                    for color in colors.dropFirst(images.count) {
                        images.append(Image(width: first.width, height: first.height, color: color.colorValue ?? .white))
                    }
                }
                try tileMap.setImagePalette(images, cells: cells)
            } else if case let .array(colorValues) = payload["atlasColors"], !colorValues.isEmpty {
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
                for cell in cells where cell.count >= 3 && colorValues.indices.contains(cell[2]) {
                    tileMap.layers[0].setCell(
                        at: [cell[0], cell[1]],
                        sourceId: sourceID,
                        atlasCoordinates: [cell[2], 0]
                    )
                }
            }
            if let path = payload["tileSetReference"]?.stringValue, !path.isEmpty {
                let handle = try AssetsManager.loadSync(TileSet.self, at: path)
                guard let linkedSet = handle.asset else {
                    throw EditorTileMapReferenceError.invalid(path)
                }
                var palette: [TileMapSourceTile] = []
                if case let .array(entries) = payload["tileSetTiles"] {
                    for entry in entries {
                        guard case let .object(fields) = entry,
                            let sourceID = fields["sourceID"]?.doubleValue.map(Int.init),
                            case let .array(coordinates)? = fields["atlasCoordinates"] else { continue }
                        palette.append(TileMapSourceTile(
                            sourceID: sourceID,
                            atlasCoordinates: coordinates.compactMap { $0.doubleValue.map(Int.init) }
                        ))
                    }
                }
                let legacyCount = max(payload["atlasColors"]?.tileMapArrayCount ?? 0, payload["atlasTextures"]?.tileMapArrayCount ?? 0)
                try tileMap.installTileSetPalette(linkedSet, palette: palette, cells: cells, firstPaletteIndex: legacyCount)
            }
            return TileMapComponent(
                tileMap: tileMap,
                tileDisplaySize: Size(width: size.x, height: size.y)
            )
        }
    )
}

private extension EditorSceneValue {
    var tileMapArrayCount: Int {
        if case let .array(values) = self { return values.count }
        return 0
    }
}
