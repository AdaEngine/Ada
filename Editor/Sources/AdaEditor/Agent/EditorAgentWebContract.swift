import AdaEngine
import AdaScriptCompilerCore
import AdaStudioCore
import Foundation

/// Build-time references from Studio's native descriptors and input codecs.
/// Web Player supports fewer fields than native Studio; ignored native fields
/// are listed separately rather than advertised as browser authoring features.
@MainActor
enum EditorAgentWebContract {
    static func encoded() throws -> Data {
        EditorComponentRegistry.registerBuiltIns()
        let descriptors = EditorComponentRegistry.descriptors.filter { StudioRuntimeCapabilities.components.contains(wireType($0.typeName)) }
        let missing = StudioRuntimeCapabilities.components.subtracting(descriptors.map { wireType($0.typeName) })
        guard missing.isEmpty else {
            throw EditorCLIError.environment("Missing native descriptors for supported Web Player components: \(missing.sorted().joined(separator: ", ")).")
        }
        let value: [String: Any] = [
            "version": 1,
            "runtimeAPI": StudioRuntimeCapabilities.webPlayerAPI,
            "agentToolsVersion": 2,
            "source": "Native Studio descriptors, InputBinding Codable and AdaScript compiler type environment",
            "components": try descriptors.sorted { $0.typeName < $1.typeName }.map(component),
            "input": try input(),
            "api": api(),
            "examples": try EditorAgentKnowledge.examples.map { example -> [String: Any] in
                var assets: [String: String] = [:]
                if example.id == "side-scroller-3d" {
                    for cue in ["flap", "score", "crash"] {
                        guard let source = example.files["Generators/\(cue).sound.txt"] else { throw EditorCLIError.environment("Missing bundled sound generator: \(cue)") }
                        assets["Assets/Audio/\(cue).wav"] = try WAVWriter().encode(AdaScriptSoundGenerator.generate(source: source)).base64EncodedString()
                    }
                }
                return ["id": example.id, "description": example.description, "tags": example.tags, "files": example.files, "assets": assets]
            },
        ]
        return try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    }

    private static let browserFields: [String: Set<String>] = [
        "AdaTransform.Transform": ["position", "rotation", "scale"],
        "AdaRender.Visibility": ["value"],
        "AdaRender.Camera": ["projection", "isActive", "renderOrder", "backgroundColor"],
        "AdaSprite.Sprite": ["texture", "tintColor", "size", "flipX", "flipY", "anchor", "imageMode"],
        "AdaSprite.Mesh2D": ["mesh", "size", "color"],
        "AdaScene.Mesh3DComponent": ["mesh", "size", "color", "metallic", "roughness", "castShadows", "receiveShadows"],
        "AdaScene.Model3DSource": ["source", "animation", "autoplay", "repeats"],
        "AdaScene.DirectionalLightComponent": ["radiance", "intensity", "castShadows"],
        "AdaAudio.AudioSource": ["source", "volume", "loops", "autoplay"],
    ]

    private static func wireType(_ native: String) -> String {
        // Keep the established Player wire key when the defining Swift module
        // differs; persisted scene names are a protocol, not reflection output.
        native == EditorBuiltInComponentType.environment3D ? "AdaRender.Environment3D" : native
    }

    private static func component(_ descriptor: EditorComponentDescriptor) throws -> [String: Any] {
        let typeName = wireType(descriptor.typeName)
        let allowed = browserFields[typeName]
        let payload = descriptor.makeDefaultPayload().filter { allowed?.contains($0.key) ?? true }
        var portablePayload = EditorSceneValue.object(payload)
        for field in descriptor.fields where field.coding == .unsignedInteger {
            if case let .uint(value)? = field.storedValue(in: payload), value > 9_007_199_254_740_991 {
                let path = field.valuePath.isEmpty ? [field.key] : field.valuePath
                portablePayload.setValue(.string(String(value)), at: path[...])
            }
        }
        var fields = descriptor.fields.filter { allowed?.contains($0.valuePath.first ?? $0.key) ?? true }
            .map { field -> [String: Any] in
                var value: [String: Any] = ["name": field.key, "kind": String(describing: field.kind), "coding": String(describing: field.coding), "editable": field.isEditable]
                value["path"] = field.valuePath.isEmpty ? [field.key] : field.valuePath
                if case let .enumeration(cases) = field.kind { value["cases"] = cases }
                if let minimum = field.minimumValue { value["minimum"] = minimum }
                // The fixed browser player uses the wasm32 ABI. Native Int
                // fields must not advertise the exporter's host Int64 range.
                if case .int = field.kind {
                    value["minimum"] = max(field.minimumValue ?? Double(Int32.min), Double(Int32.min))
                    value["maximum"] = Double(Int32.max)
                }
                return value
            }
        for index in fields.indices {
            if typeName == "AdaSprite.Sprite", fields[index]["name"] as? String == "imageMode" {
                fields[index]["examples"] = try ["stretch": SpriteImageMode.stretch, "fit": .fit, "fill": .fill,
                    "sliced": .sliced(SpriteSliceBorder(4)), "tiled": .tiled()].mapValues { try object($0) }
            }
            if typeName == "AdaPhysics.PhysicsBody2DComponent", fields[index]["name"] as? String == "shapes" {
                fields[index]["examples"] = try ["box": Shape2DResource.generateBox(), "circle": .generateCircle(),
                    "polygon": .generatePolygon(vertices: [Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0, 0.5)])].mapValues { try object([$0]) }
            }
        }
        var defaultPayload = try object(portablePayload)
        var defaultPayloadJSON = try JSONEncoder().encode(payload)
        // Native Studio resolves tile-map inspector state; Web Player decodes
        // an explicit resource path and display size instead.
        if descriptor.typeName == "AdaTilemap.TileMapComponent" {
            defaultPayload = ["map": "@res://Maps/Level.tilemap", "tileDisplaySize": [32, 32]]
            defaultPayloadJSON = try JSONSerialization.data(withJSONObject: defaultPayload, options: .sortedKeys)
            fields = [["name": "map", "path": ["map"], "kind": "assetReference", "coding": "standard", "editable": true],
                      ["name": "tileDisplaySize", "path": ["tileDisplaySize"], "kind": "vector2", "coding": "standard", "editable": true]]
        }
        return [
            "typeName": typeName, "nativeTypeName": descriptor.typeName, "description": descriptor.description,
            "requiredComponents": descriptor.requiredComponentTypeNames.map(wireType).filter { StudioRuntimeCapabilities.components.contains($0) },
            "defaultPayload": defaultPayload, "fields": fields, "platforms": ["web"],
            "defaultPayloadJSON": String(decoding: defaultPayloadJSON, as: UTF8.self),
            "integerEncoding": "unsignedInteger tool fields use decimal strings beyond the JavaScript safe integer range; defaultPayloadJSON preserves native numeric encoding",
            "requiresAsset": ["AdaScene.Model3DSource", "AdaAudio.AudioSource", "AdaTilemap.TileMapComponent"].contains(descriptor.typeName),
            "ignoredNativeFields": descriptor.fields.filter { !(allowed?.contains($0.valuePath.first ?? $0.key) ?? true) }.map(\.key),
        ]
    }

    private static func object<T: Encodable>(_ value: T) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(value), options: .fragmentsAllowed)
    }

    private static func input() throws -> [String: Any] {
        var bindings: [[String: Any]] = []
        func add(_ kind: String, _ name: String, _ binding: InputBinding) throws {
            try InputAction.validate([InputAction(name: "Probe", bindings: [binding])])
            let data = try JSONEncoder().encode(binding)
            guard try JSONDecoder().decode(InputBinding.self, from: data) == binding else {
                throw EditorCLIError.environment("InputBinding round-trip failed.")
            }
            bindings.append(["kind": kind, "name": name, "encoded": try JSONSerialization.jsonObject(with: data)])
        }
        for key in KeyCode.allCases where key != .none { try add("key", String(describing: key), .key(key)) }
        for button in MouseButton.allCases where button != .none && button != .scrollWheel { try add("mouseButton", String(describing: button), .mouseButton(button)) }
        for button in GamepadButton.allCases where button != .unknown { try add("gamepadButton", String(describing: button), .gamepadButton(button)) }
        for axis in GamepadAxis.allCases where axis != .unknown {
            for direction in InputAxisDirection.allCases {
                try add("gamepadAxis", "\(axis).\(direction)", .gamepadAxis(axis, direction))
            }
        }
        for direction in InputAxisDirection.allCases { try add("mouseScroll", String(describing: direction), .mouseScroll(direction)) }
        try add("mouseMotion", "mouseMotion", .mouseMotion)
        try add("touch", "touch", .touch)
        for phase in InputTouchPhase.allCases { try add("touchEvent", String(describing: phase), .touchEvent(phase)) }
        return ["bindings": bindings, "defaultDeadZone": 0.2, "deadZoneRange": [0, 1], "maximumExclusive": true,
                "example": try object([InputAction(name: "Jump", bindings: [.key(.space), .mouseButton(.left), .touch])])]
    }

    private static func api() -> [String: Any] {
        let environment = AdaScriptTypeEnvironment.standard
        return [
            "types": environment.members.keys.sorted().map { type in
                ["name": type, "members": (environment.members[type] ?? [:]).sorted { $0.key < $1.key }.map { name, member -> [String: Any] in
                    var value: [String: Any] = ["name": name, "type": member.type.displayName, "description": member.detail ?? "", "insertText": member.insertText ?? name]
                    if let callable = member.callable {
                        value["parameters"] = callable.parameters.map(\.displayName)
                        value["returnType"] = callable.returnType.displayName
                    }
                    return value
                }] as [String: Any]
            },
            "functions": environment.functions.sorted { $0.key < $1.key }.map { name, callable in
                ["name": name, "parameters": callable.parameters.map(\.displayName), "returnType": callable.returnType.displayName] as [String: Any]
            },
        ]
    }
}
