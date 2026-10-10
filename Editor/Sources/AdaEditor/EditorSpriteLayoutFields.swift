@_spi(AdaEngine) import AdaEngine

/// Inspector controls keep the runtime Codable layout rather than a second scene schema.
enum EditorSpriteLayoutFields {
    static let anchors: [(String, SpriteAnchor)] = [
        ("Center", .center), ("Bottom Left", .bottomLeft), ("Bottom Center", .bottomCenter), ("Bottom Right", .bottomRight),
        ("Center Left", .centerLeft), ("Center Right", .centerRight),
        ("Top Left", .topLeft), ("Top Center", .topCenter), ("Top Right", .topRight),
    ]
    static let modes = ["stretch", "fit", "fill", "sliced", "tiled"]
    static var sizeField: EditorComponentField {
        var field = EditorComponentField(key: "size", label: "Size", kind: .vector2)
        field.coding = .spriteSize
        return field
    }
    static var fields: [EditorComponentField] {
        var preset = EditorComponentField(key: "anchorPreset", label: "Anchor", kind: .enumeration(anchors.map(\.0) + ["Custom"]))
        preset.coding = .spriteAnchorPreset
        var anchor = EditorComponentField(key: "anchor", label: "Anchor X / Y", kind: .vector2)
        anchor.coding = .vectorObject
        anchor.defaultValue = .object(["x": .double(0), "y": .double(0)])
        var mode = EditorComponentField(key: "imageMode", label: "Image Mode", kind: .enumeration(modes))
        mode.coding = .spriteImageMode
        mode.defaultValue = .object(["stretch": .object([:])])
        return [preset, anchor, mode]
            + ["top", "left", "bottom", "right"].map {
                nested("sliced._0.\($0)", "Slice \($0.capitalized) (px)", .float, .double(0), minimum: 0)
            } + [
                nested("tiled.tileX", "Tile X", .bool, .bool(true)),
                nested("tiled.tileY", "Tile Y", .bool, .bool(true)),
                nested("tiled.scale", "Tile Scale", .float, .double(1), minimum: Double(Float.leastNonzeroMagnitude)),
            ]
    }

    static func isVisible(_ field: EditorComponentField, in payload: EditorComponentPayload) -> Bool {
        guard field.valuePath.first == "imageMode", field.valuePath.count > 1 else {
            return true
        }
        guard case .object(let mode)? = payload["imageMode"] else {
            return false
        }
        return mode[field.valuePath[1]] != nil
    }

    static func anchorPreset(in payload: EditorComponentPayload) -> String {
        guard case .object(let axes)? = payload["anchor"], let x = axes["x"]?.doubleValue, let y = axes["y"]?.doubleValue else {
            return "Center"
        }
        let anchor = SpriteAnchor(x: Float(x), y: Float(y))
        return anchors.first { $0.1.x == anchor.x && $0.1.y == anchor.y }?.0 ?? "Custom"
    }

    static func writeAnchorPreset(_ name: String, to payload: inout EditorComponentPayload) {
        guard let anchor = anchors.first(where: { $0.0 == name })?.1 else {
            return
        }
        payload["anchor"] = .object(["x": .double(Double(anchor.x)), "y": .double(Double(anchor.y))])
    }

    static func writeImageMode(_ mode: String, to payload: inout EditorComponentPayload) {
        guard modes.contains(mode) else {
            return
        }
        if case .object(let current)? = payload["imageMode"], current[mode] != nil {
            return
        }
        let values: EditorSceneValue =
            switch mode {
            case "sliced": .object(["_0": .object(["top": .double(0), "left": .double(0), "bottom": .double(0), "right": .double(0)])])
            case "tiled": .object(["tileX": .bool(true), "tileY": .bool(true), "scale": .double(1)])
            default: .object([:])
            }
        payload["imageMode"] = .object([mode: values])
    }

    private static func nested(
        _ path: String, _ label: String, _ kind: EditorComponentFieldKind, _ defaultValue: EditorSceneValue, minimum: Double? = nil
    ) -> EditorComponentField {
        var field = EditorComponentField(key: "imageMode.\(path)", label: label, kind: kind)
        field.valuePath = ["imageMode"] + path.split(separator: ".").map(String.init)
        field.defaultValue = defaultValue
        field.minimumValue = minimum
        return field
    }
}
