@_spi(AdaEngine) import AdaEngine

extension EditorComponentRegistry {
    static let tileMapDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.tileMap,
        displayName: "Tile Map",
        category: "2D",
        description: "Displays an editable tile map with a configurable tile size.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            EditorComponentField(key: "tileDisplaySize", label: "Tile Size", kind: .vector2)
        ],
        makeDefaultPayload: {
            ["tileDisplaySize": .array([.double(16), .double(16)])]
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
            return TileMapComponent(
                tileMap: TileMap(),
                tileDisplaySize: Size(width: size.x, height: size.y)
            )
        }
    )
}
