@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorTerrainPayload {
    static let typeName = String(reflecting: Terrain3D.self)

    static func encode(_ terrain: Terrain3D) -> EditorComponentPayload {
        [
            "resolution": .int(terrain.resolution), "size": .double(Double(terrain.size)),
            "heights": .array(terrain.heights.map { .double(Double($0)) }),
            "color": .object([
                "x": .double(Double(terrain.color.x)), "y": .double(Double(terrain.color.y)),
                "z": .double(Double(terrain.color.z)), "w": .double(Double(terrain.color.w)),
            ]),
            "generatesCollision": .bool(terrain.generatesCollision),
        ]
    }

    static func decode(_ payload: EditorComponentPayload) -> Terrain3D? {
        try? JSONDecoder().decode(Terrain3D.self, from: JSONEncoder().encode(payload))
    }
}

extension EditorComponentRegistry {
    private static let terrainSizeField: EditorComponentField = {
        var field = EditorComponentField(key: "size", label: "Size", kind: .float)
        field.minimumValue = 0.01
        return field
    }()

    private static let terrainColorField: EditorComponentField = {
        var field = EditorComponentField(key: "color", label: "Ground Color", kind: .vector4)
        field.coding = .vectorObject
        return field
    }()

    static let terrainDescriptor = EditorComponentDescriptor(
        typeName: EditorTerrainPayload.typeName,
        displayName: "Terrain",
        category: "3D",
        description: "Shape the ground with the terrain brush in the 3D viewport.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform, EditorBuiltInComponentType.visibility],
        fields: [
            terrainSizeField,
            EditorComponentField(key: "resolution", label: "Resolution", kind: .int, isEditable: false),
            terrainColorField,
            EditorComponentField(key: "generatesCollision", label: "Ground Collision", kind: .bool),
        ],
        makeDefaultPayload: { EditorTerrainPayload.encode(Terrain3D()) },
        decode: { payload in
            try JSONDecoder().decode(Terrain3D.self, from: JSONEncoder().encode(payload))
        }
    )
}
