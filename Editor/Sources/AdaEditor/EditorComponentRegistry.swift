@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorBuiltInComponentType {
    static let transform = String(reflecting: Transform.self)
    static let camera = String(reflecting: Camera.self)
    static let sprite = String(reflecting: Sprite.self)
    static let visibility = String(reflecting: Visibility.self)
    static let light2D = String(reflecting: Light2D.self)
    static let lightOccluder2D = String(reflecting: LightOccluder2D.self)
    static let lightModulate2D = String(reflecting: LightModulate2D.self)
    static let globalTransform = String(reflecting: GlobalTransform.self)
    static let bounding = String(reflecting: BoundingComponent.self)
    static let scriptableComponents = String(reflecting: ScriptableComponents.self)
    static let companionPanel = String(reflecting: CompanionPanel.self)
    static let uiComponent = String(reflecting: UIComponent.self)
    static let sceneInstance = String(reflecting: SceneInstance.self)
    static let physicsBody2D = String(reflecting: PhysicsBody2DComponent.self)
    static let mesh2D = String(reflecting: Mesh2D.self)
    static let mesh3D = String(reflecting: Mesh3DComponent.self)
    static let physicsBody3D = String(reflecting: PhysicsBody3DComponent.self)
    static let directionalLight3D = String(reflecting: DirectionalLightComponent.self)
    static let pointLight3D = String(reflecting: PointLightComponent.self)
    static let spotLight3D = String(reflecting: SpotLightComponent.self)
    static let environment3D = String(reflecting: Environment3D.self)
    static let tileMap = String(reflecting: TileMapComponent.self)
}

enum EditorComponentFieldKind: Equatable, Sendable {
    case bool
    case int
    case float
    case string
    case enumeration([String])
    case vector2
    case vector3
    case vector4
    case color
    case assetReference
    case sceneReference
    case readOnly
}

extension EditorComponentFieldKind {
    init(reflectedKind: ReflectedFieldKind) {
        switch reflectedKind {
        case .bool:
            self = .bool
        case .int:
            self = .int
        case .float:
            self = .float
        case .string:
            self = .string
        case let .enumeration(cases):
            self = .enumeration(cases)
        case .vector2:
            self = .vector2
        case .vector3:
            self = .vector3
        case .vector4:
            self = .vector4
        case .color:
            self = .color
        case .assetReference:
            self = .assetReference
        case .readOnly:
            self = .readOnly
        }
    }
}

struct EditorComponentField: Equatable, Identifiable, Sendable {
    var id: String { key }
    var key: String
    var label: String
    var kind: EditorComponentFieldKind
    var isEditable: Bool
    var valuePath: [String] = []
    var coding: EditorComponentFieldCoding = .standard
    var defaultValue: EditorSceneValue?
    var minimumValue: Double?

    init(key: String, label: String, kind: EditorComponentFieldKind, isEditable: Bool = true) {
        self.key = key
        self.label = label
        self.kind = kind
        self.isEditable = isEditable
    }

    func displayValue(in payload: EditorComponentPayload) -> String {
        let value = storedValue(in: payload) ?? defaultValue
        if coding == .enumCase, case let .object(cases) = value {
            return cases.keys.min() ?? ""
        }
        if coding == .json {
            return value?.jsonString ?? ""
        }
        if coding == .vectorObject, case let .object(axes) = value {
            let count = kind == .vector2 ? 2 : (kind == .vector3 ? 3 : 4)
            return ["x", "y", "z", "w"].prefix(count)
                .map { axes[$0]?.stringValue ?? "0" }.joined(separator: ", ")
        }
        switch kind {
        case .color:
            guard let color = value?.colorComponents else {
                return ""
            }
            return color.map(EditorSceneModelFormatting.format).joined(separator: ", ")
        default:
            return value?.stringValue ?? ""
        }
    }

    func write(_ rawValue: String, to payload: inout EditorComponentPayload) {
        guard isEditable else {
            return
        }
        if let minimumValue {
            guard let number = Double(rawValue), number.isFinite, number >= minimumValue else {
                return
            }
        }
        var temporary: EditorComponentPayload = [:]
        writePlainValue(rawValue, to: &temporary)
        guard var value = temporary[key] else {
            return
        }
        switch coding {
        case .standard: break
        case .enumCase: value = .object([value.stringValue: .object([:])])
        case .json:
            guard let decoded = try? JSONDecoder().decode(EditorSceneValue.self, from: Data(rawValue.utf8)) else {
                return
            }
            value = decoded
        case .unsignedInteger:
            guard let number = UInt64(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                return
            }
            value = .uint(number)
        case .vectorObject:
            guard case let .array(axes) = value else {
                return
            }
            value = .object(Dictionary(uniqueKeysWithValues: zip(["x", "y", "z", "w"], axes)))
        }
        if valuePath.isEmpty {
            payload[key] = value
        } else {
            var root = EditorSceneValue.object(payload)
            root.setValue(value, at: valuePath[...])
            if case let .object(updated) = root {
                payload = updated
            }
        }
    }

    private func writePlainValue(_ rawValue: String, to payload: inout EditorComponentPayload) {
        guard isEditable else {
            return
        }

        switch kind {
        case .bool:
            payload[key] = .bool(rawValue.lowercased() == "true" || rawValue == "1")
        case .int:
            payload[key] = .int(Int(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case .float:
            payload[key] = .double(Double(rawValue.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case .string,
            .assetReference,
            .sceneReference:
            payload[key] = rawValue.isEmpty ? .null : .string(rawValue)
        case let .enumeration(cases):
            payload[key] = .string(cases.contains(rawValue) ? rawValue : cases.first ?? rawValue)
        case .vector2:
            payload[key] = .array(Self.parseVector(rawValue, count: 2))
        case .vector3:
            payload[key] = .array(Self.parseVector(rawValue, count: 3))
        case .vector4:
            payload[key] = .array(Self.parseVector(rawValue, count: 4))
        case .color:
            let values = Self.parseVector(rawValue, count: 4).map { $0.doubleValue ?? 0 }
            payload[key] = .object([
                "red": .double(values[0]),
                "green": .double(values[1]),
                "blue": .double(values[2]),
                "alpha": .double(values[3]),
            ])
        case .readOnly:
            break
        }
    }

    private static func parseVector(_ value: String, count: Int) -> [EditorSceneValue] {
        var numbers =
            value
            .split { $0 == "," || $0 == " " || $0 == "\t" }
            .map { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0 }
        if numbers.count < count {
            numbers.append(contentsOf: Array(repeating: 0, count: count - numbers.count))
        }
        return numbers.prefix(count).map(EditorSceneValue.double)
    }
}

struct EditorComponentDescriptor: @unchecked Sendable {
    var typeName: String
    var displayName: String
    var category: String
    var description: String
    var requiredComponentTypeNames: [String]
    var fields: [EditorComponentField]
    var makeDefaultPayload: @Sendable () -> EditorComponentPayload
    var decode: @Sendable (EditorComponentPayload) throws -> any Component
}

enum EditorComponentRegistry {
    static var descriptors: [EditorComponentDescriptor] {
        let overrideNames = Set(overrideDescriptors.map(\.typeName))
        let reflectedDescriptors =
            ComponentReflectionRegistry
            .allDescriptors()
            .filter { !overrideNames.contains($0.typeName) }
            .map(editorDescriptor(from:))
        return overrideDescriptors + reflectedDescriptors
    }

    private static let overrideDescriptors: [EditorComponentDescriptor] = [
        transformDescriptor,
        cameraDescriptor,
        spriteDescriptor,
        visibilityDescriptor,
        light2DDescriptor,
        lightOccluder2DDescriptor,
        lightModulate2DDescriptor,
        physicsBody2DDescriptor,
        mesh2DDescriptor,
        mesh3DDescriptor,
        physicsBody3DDescriptor,
        directionalLight3DDescriptor,
        pointLight3DDescriptor,
        spotLight3DDescriptor,
        environment3DDescriptor,
        tileMapDescriptor,
        sceneInstanceDescriptor,
        uiComponentDescriptor,
        companionPanelDescriptor,
    ]

    private static let overrideDescriptorsByName: [String: EditorComponentDescriptor] = Dictionary(
        uniqueKeysWithValues: overrideDescriptors.map { ($0.typeName, $0) }
    )

    @MainActor
    static func registerBuiltIns() {
        DisplayLayout.registerRuntimeType()
        RuntimeTypeRegistry.registerComponent(CompanionPanel.self, names: ["CompanionPanel"])
        RuntimeTypeRegistry.registerComponent(
            Transform.self,
            names: ["Transform"],
            makeDefault: { Transform() }
        )
        RuntimeTypeRegistry.registerComponent(GlobalTransform.self, names: ["GlobalTransform"])
        RuntimeTypeRegistry.registerComponent(Camera.self, names: ["Camera"])
        RuntimeTypeRegistry.registerComponent(
            Sprite.self,
            names: ["Sprite"],
            makeDefault: { Sprite(texture: Texture2D.whiteTexture) }
        )
        RuntimeTypeRegistry.registerComponent(
            NoFrustumCulling.self,
            names: ["NoFrustumCulling", String(reflecting: NoFrustumCulling.self)],
            makeDefault: { NoFrustumCulling() }
        )
        RuntimeTypeRegistry.registerComponent(Visibility.self, names: ["Visibility"])
        RuntimeTypeRegistry.registerComponent(BoundingComponent.self, names: ["BoundingComponent"])
        RuntimeTypeRegistry.registerComponent(Light2D.self, names: ["Light2D"])
        RuntimeTypeRegistry.registerComponent(LightOccluder2D.self, names: ["LightOccluder2D"])
        RuntimeTypeRegistry.registerComponent(LightModulate2D.self, names: ["LightModulate2D"])
        RuntimeTypeRegistry.registerComponent(SceneInstance.self, names: ["SceneInstance"])
        RuntimeTypeRegistry.registerComponent(UIComponent.self, names: ["UIComponent"])
        RuntimeTypeRegistry.registerComponent(PhysicsBody2DComponent.self, names: ["PhysicsBody2DComponent"])
        RuntimeTypeRegistry.registerComponent(Mesh2D.self, names: ["Mesh2D"])
        RuntimeTypeRegistry.registerComponent(Mesh3DComponent.self, names: ["Mesh3DComponent"])
        RuntimeTypeRegistry.registerComponent(PhysicsBody3DComponent.self, names: ["PhysicsBody3DComponent"])
        RuntimeTypeRegistry.registerComponent(DirectionalLightComponent.self, names: ["DirectionalLightComponent"])
        RuntimeTypeRegistry.registerComponent(PointLightComponent.self, names: ["PointLightComponent"])
        RuntimeTypeRegistry.registerComponent(SpotLightComponent.self, names: ["SpotLightComponent"])
        RuntimeTypeRegistry.registerComponent(Environment3D.self, names: ["Environment3D"])
        RuntimeTypeRegistry.registerComponent(TileMapComponent.self, names: ["TileMapComponent"])

        ComponentReflectionRegistry.register(Transform.componentDescriptor)
        ComponentReflectionRegistry.register(GlobalTransform.componentDescriptor)
        ComponentReflectionRegistry.register(Camera.componentDescriptor)
        ComponentReflectionRegistry.register(Sprite.componentDescriptor)
        ComponentReflectionRegistry.register(Visibility.componentDescriptor)
        ComponentReflectionRegistry.register(BoundingComponent.componentDescriptor)
        ComponentReflectionRegistry.register(Light2D.componentDescriptor)
        ComponentReflectionRegistry.register(LightOccluder2D.componentDescriptor)
        ComponentReflectionRegistry.register(LightModulate2D.componentDescriptor)
        ComponentReflectionRegistry.register(SceneInstance.componentDescriptor)
    }

    static func descriptor(named typeName: String) -> EditorComponentDescriptor? {
        overrideDescriptorsByName[typeName] ?? ComponentReflectionRegistry.descriptor(named: typeName).map(editorDescriptor(from:))
    }

    static func addableDescriptors(for entity: EditorSceneEntity?) -> [EditorComponentDescriptor] {
        descriptors.filter { descriptor in
            guard let entity else {
                return true
            }
            return entity.components[descriptor.typeName] == nil
        }
    }

    static func defaultPayload(for typeName: String) -> EditorComponentPayload {
        overrideDescriptorsByName[typeName]?.makeDefaultPayload() ?? [:]
    }

    static func decode(typeName: String, payload: EditorComponentPayload) throws -> (any Component)? {
        if let descriptor = overrideDescriptorsByName[typeName] {
            return try descriptor.decode(payload)
        }

        guard
            let componentType = RuntimeTypeRegistry.componentType(named: typeName),
            let decodableType = componentType as? Decodable.Type
        else {
            return nil
        }
        let value = try EditorComponentPayloadDecoder.decode(decodableType, payload: payload)
        return value as? any Component
    }

    private static func editorDescriptor(from descriptor: AdaECS.ReflectedComponentDescriptor) -> EditorComponentDescriptor {
        EditorComponentDescriptor(
            typeName: descriptor.typeName,
            displayName: descriptor.displayName,
            category: "Reflected",
            description: "A reflected \(descriptor.displayName) component with \(descriptor.fields.count) editable propert\(descriptor.fields.count == 1 ? "y" : "ies").",
            requiredComponentTypeNames: descriptor.requiredComponentTypeNames,
            fields: descriptor.fields.map {
                EditorComponentField(
                    key: $0.key,
                    label: $0.label,
                    kind: EditorComponentFieldKind(reflectedKind: $0.kind),
                    isEditable: $0.isWritable
                )
            },
            makeDefaultPayload: { [:] },
            decode: { payload in
                guard
                    let componentType = RuntimeTypeRegistry.componentType(named: descriptor.typeName),
                    let decodableType = componentType as? Decodable.Type,
                    let component = try EditorComponentPayloadDecoder.decode(decodableType, payload: payload) as? any Component
                else {
                    throw DecodingError.dataCorrupted(
                        DecodingError.Context(codingPath: [], debugDescription: "Cannot decode reflected component \(descriptor.typeName)")
                    )
                }
                return component
            }
        )
    }
}

extension EditorComponentRegistry {
    private static let transformDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.transform,
        displayName: "Transform",
        category: "Core",
        description: "Controls the entity's position, rotation, and scale in the scene.",
        requiredComponentTypeNames: [],
        fields: [
            EditorComponentField(key: "position", label: "Position", kind: .vector3),
            EditorComponentField(key: "rotation", label: "Rotation", kind: .vector4),
            EditorComponentField(key: "scale", label: "Scale", kind: .vector3),
        ],
        makeDefaultPayload: {
            [
                "position": .array([.double(0), .double(0), .double(0)]),
                "rotation": .array([.double(0), .double(0), .double(0), .double(1)]),
                "scale": .array([.double(1), .double(1), .double(1)]),
            ]
        },
        decode: { payload in
            try EditorComponentPayloadDecoder.decode(Transform.self, payload: payload) as! Transform
        }
    )

    private static let cameraDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.camera,
        displayName: "Camera",
        category: "Rendering",
        description: "Renders the scene from this entity with configurable order and background.",
        requiredComponentTypeNames: [],
        fields: {
            var projection = EditorComponentField(
                key: "projection",
                label: "Projection",
                kind: .enumeration(["orthographic", "perspective"])
            )
            projection.defaultValue = .string("orthographic")
            return [
                projection,
                EditorComponentField(key: "isActive", label: "Active", kind: .bool),
                EditorComponentField(key: "renderOrder", label: "Render Order", kind: .int),
                EditorComponentField(key: "backgroundColor", label: "Background", kind: .color),
            ]
        }(),
        makeDefaultPayload: {
            [
                "projection": .string("orthographic"),
                "isActive": .bool(true),
                "renderOrder": .int(0),
                "backgroundColor": .object([
                    "red": .double(43.0 / 255.0),
                    "green": .double(44.0 / 255.0),
                    "blue": .double(47.0 / 255.0),
                    "alpha": .double(1),
                ]),
            ]
        },
        decode: { payload in
            var camera = Camera()
            if payload["projection"]?.stringValue == "perspective" {
                camera.projection = .perspective(PerspectiveProjection())
            } else {
                camera.projection = .orthographic(OrthographicProjection())
            }
            camera.isActive = payload["isActive"]?.boolValue ?? true
            camera.renderOrder = Int(payload["renderOrder"]?.doubleValue ?? 0)
            camera.backgroundColor = payload["backgroundColor"]?.colorValue ?? .surfaceClearColor
            return camera
        }
    )

    private static let spriteDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.sprite,
        displayName: "Sprite",
        category: "2D",
        description: "Draws a 2D texture with tint, flip, and size controls.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.visibility],
        fields: [
            EditorComponentField(key: "tintColor", label: "Tint", kind: .color),
            EditorComponentField(key: "flipX", label: "Flip X", kind: .bool),
            EditorComponentField(key: "flipY", label: "Flip Y", kind: .bool),
            EditorComponentField(key: "texture", label: "Texture", kind: .assetReference),
            EditorComponentField(key: "size", label: "Size", kind: .vector2),
        ],
        makeDefaultPayload: {
            [
                "texture": .null,
                "tintColor": .object(["red": .double(1), "green": .double(1), "blue": .double(1), "alpha": .double(1)]),
                "flipX": .bool(false),
                "flipY": .bool(false),
                "size": .null,
            ]
        },
        decode: { payload in
            let texture: AssetHandle<Texture2D>?
            if let textureReference = payload["texture"]?.stringValue, !textureReference.isEmpty {
                texture = try? AssetsManager.loadSync(Texture2D.self, at: textureReference)
            } else {
                texture = nil
            }
            let size = payload["size"]?.vector2Value.map { Size(width: $0.x, height: $0.y) }
            return Sprite(
                texture: texture,
                tintColor: payload["tintColor"]?.colorValue ?? .white,
                flipX: payload["flipX"]?.boolValue ?? false,
                flipY: payload["flipY"]?.boolValue ?? false,
                size: size
            )
        }
    )

    private static let visibilityDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.visibility,
        displayName: "Visibility",
        category: "Rendering",
        description: "Controls whether the entity is visible or inherits visibility from its parent.",
        requiredComponentTypeNames: [],
        fields: [
            EditorComponentField(key: "value", label: "State", kind: .enumeration(["visible", "hidden", "inherited"]))
        ],
        makeDefaultPayload: {
            ["value": .string("visible")]
        },
        decode: { payload in
            switch payload["value"]?.stringValue {
            case "hidden":
                return Visibility.hidden
            case "inherited":
                return Visibility.inherited
            default:
                return Visibility.visible
            }
        }
    )

    private static let light2DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.light2D,
        displayName: "Light 2D",
        category: "2D",
        description: "Adds a point or directional light to a 2D scene.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.visibility],
        fields: [
            EditorComponentField(key: "kind", label: "Kind", kind: .enumeration(["point", "directional"])),
            EditorComponentField(key: "color", label: "Color", kind: .color),
            EditorComponentField(key: "energy", label: "Energy", kind: .float),
            EditorComponentField(key: "isEnabled", label: "Enabled", kind: .bool),
            EditorComponentField(key: "direction", label: "Direction", kind: .vector2),
            EditorComponentField(key: "radius", label: "Radius", kind: .float),
            EditorComponentField(key: "spotAngle", label: "Spot Angle", kind: .float),
            EditorComponentField(key: "castsShadows", label: "Casts Shadows", kind: .bool),
        ],
        makeDefaultPayload: {
            [
                "kind": .string("point"),
                "color": .object(["red": .double(1), "green": .double(1), "blue": .double(1), "alpha": .double(1)]),
                "energy": .double(1),
                "isEnabled": .bool(true),
                "direction": .array([.double(0), .double(-1)]),
                "radius": .double(400),
                "spotAngle": .double(0),
                "texture": .null,
                "castsShadows": .bool(true),
            ]
        },
        decode: { payload in
            Light2D(
                kind: payload["kind"]?.stringValue == "directional" ? .directional : .point,
                color: payload["color"]?.colorValue ?? .white,
                energy: Float(payload["energy"]?.doubleValue ?? 1),
                isEnabled: payload["isEnabled"]?.boolValue ?? true,
                direction: payload["direction"]?.vector2Value ?? Vector2(0, -1),
                radius: Float(payload["radius"]?.doubleValue ?? 400),
                spotAngle: Float(payload["spotAngle"]?.doubleValue ?? 0),
                texture: nil,
                castsShadows: payload["castsShadows"]?.boolValue ?? true
            )
        }
    )

    private static let lightOccluder2DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.lightOccluder2D,
        displayName: "Light Occluder 2D",
        category: "2D",
        description: "Defines geometry that blocks 2D lights and casts shadows.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.visibility],
        fields: [
            EditorComponentField(key: "isEnabled", label: "Enabled", kind: .bool),
            EditorComponentField(key: "points", label: "Points", kind: .readOnly, isEditable: false),
        ],
        makeDefaultPayload: {
            ["points": .array([]), "isEnabled": .bool(true)]
        },
        decode: { payload in
            try EditorComponentPayloadDecoder.decode(LightOccluder2D.self, payload: payload) as! LightOccluder2D
        }
    )

    private static let lightModulate2DDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.lightModulate2D,
        displayName: "Light Modulate 2D",
        category: "2D",
        description: "Applies a global ambient light color to a 2D scene.",
        requiredComponentTypeNames: [],
        fields: [
            EditorComponentField(key: "color", label: "Color", kind: .color)
        ],
        makeDefaultPayload: {
            ["color": .object(["red": .double(1), "green": .double(1), "blue": .double(1), "alpha": .double(1)])]
        },
        decode: { payload in
            try EditorComponentPayloadDecoder.decode(LightModulate2D.self, payload: payload) as! LightModulate2D
        }
    )

    private static let uiComponentDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.uiComponent,
        displayName: "UI Component",
        category: "UI",
        description: "Displays a UI scene, AdaScript View, or exported Swift View.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            .init(key: "kind", label: "Source", kind: .enumeration(["ui", "script", "swiftView"])),
            .init(key: "path", label: "UI / AdaScript file", kind: .string),
            .init(key: "identifier", label: "View identifier", kind: .string),
            .init(key: "contextName", label: "Data context", kind: .string),
            .init(key: "inputs", label: "Inputs (JSON)", kind: .string),
            .init(key: "scriptBindings", label: "Script field bindings", kind: .string),
            .init(key: "behaviour", label: "Behaviour", kind: .enumeration(["overlay", "default"])),
        ],
        makeDefaultPayload: {
            ["kind": .string("ui"), "path": .string(""), "identifier": .string(""), "contextName": .string(""), "inputs": .string("{}"), "behaviour": .string("overlay")]
        },
        decode: { payload in
            let inputsText = payload["inputs"]?.stringValue ?? "{}"
            let inputs = try JSONDecoder().decode([String: UIValue].self, from: Data(inputsText.utf8))
            let bindings = try JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data((payload["scriptBindings"]?.stringValue ?? "{}").utf8))
            let source = UIComponentSource(
                kind: UIComponentSource.Kind(rawValue: payload["kind"]?.stringValue ?? "ui") ?? .ui,
                path: payload["path"]?.stringValue ?? "",
                identifier: payload["identifier"]?.stringValue ?? "",
                contextName: payload["contextName"]?.stringValue ?? "",
                inputs: inputs,
                scriptBindings: bindings
            )
            return UIComponent(source: source, behaviour: UIComponent.Behaviour(rawValue: payload["behaviour"]?.stringValue ?? "overlay") ?? .overlay)
        }
    )

    private static let companionPanelDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.companionPanel,
        displayName: "Companion Panel",
        category: "UI",
        description: "Displays a .ui scene in the secondary display region using this entity's script bindings.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            .init(key: "path", label: "UI file", kind: .string),
            .init(key: "inputs", label: "Inputs (JSON)", kind: .string),
            .init(key: "scriptBindings", label: "Script field bindings", kind: .string),
        ],
        makeDefaultPayload: { ["path": .string(""), "inputs": .string("{}"), "scriptBindings": .string("{}")] },
        decode: { payload in
            let inputs = try JSONDecoder().decode([String: UIValue].self, from: Data((payload["inputs"]?.stringValue ?? "{}").utf8))
            let bindings = try JSONDecoder().decode([String: UIScriptFieldBinding].self, from: Data((payload["scriptBindings"]?.stringValue ?? "{}").utf8))
            return CompanionPanel(source: UIComponentSource(path: payload["path"]?.stringValue ?? "", inputs: inputs, scriptBindings: bindings))
        }
    )

    private static let sceneInstanceDescriptor = EditorComponentDescriptor(
        typeName: EditorBuiltInComponentType.sceneInstance,
        displayName: "Scene Instance",
        category: "Scene",
        description: "Instantiates another scene as a reusable prefab beneath this entity.",
        requiredComponentTypeNames: [EditorBuiltInComponentType.transform],
        fields: [
            EditorComponentField(key: "scene", label: "Scene", kind: .sceneReference)
        ],
        makeDefaultPayload: {
            ["scene": .null]
        },
        decode: { payload in
            SceneInstance(scene: payload["scene"]?.stringValue ?? "")
        }
    )
}

enum EditorComponentPayloadDecoder {
    static func decode(_ type: Decodable.Type, payload: EditorComponentPayload) throws -> Any {
        let object = payload.reduce(into: [String: Any]()) { result, item in
            result[item.key] = normalizedComponentValue(item.value.jsonCompatibleValue, key: item.key)
        }
        let data = try JSONSerialization.data(withJSONObject: object, options: [])
        return try DynamicDecodableValue.decode(type, from: data)
    }

    private static func normalizedComponentValue(_ value: Any, key: String) -> Any {
        guard let array = value as? [Any] else {
            return value
        }

        switch (key, array.count) {
        case ("position", 3),
            ("scale", 3):
            return ["x": array[0], "y": array[1], "z": array[2]]
        case ("rotation", 4):
            return ["x": array[0], "y": array[1], "z": array[2], "w": array[3]]
        case ("direction", 2):
            return ["x": array[0], "y": array[1]]
        default:
            return value
        }
    }
}

private struct DynamicDecodableValue: Decodable {
    nonisolated(unsafe) private static var type: Decodable.Type?
    let value: Any

    static func decode(_ type: Decodable.Type, from data: Data) throws -> Any {
        self.type = type
        defer { self.type = nil }
        return try JSONDecoder().decode(Self.self, from: data).value
    }

    init(from decoder: Decoder) throws {
        guard let type = Self.type else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath, debugDescription: "Missing dynamic component type")
            )
        }

        self.value = try type.init(from: decoder)
    }
}

extension EditorSceneValue {
    var colorComponents: [Double]? {
        guard case let .object(object) = self else {
            return nil
        }
        return [
            object["red"]?.doubleValue ?? 0,
            object["green"]?.doubleValue ?? 0,
            object["blue"]?.doubleValue ?? 0,
            object["alpha"]?.doubleValue ?? 1,
        ]
    }

    var colorValue: Color? {
        guard let colorComponents else {
            return nil
        }
        return Color(
            red: Float(colorComponents[0]),
            green: Float(colorComponents[1]),
            blue: Float(colorComponents[2]),
            alpha: Float(colorComponents[3])
        )
    }

    var vector2Value: Vector2? {
        guard case let .array(values) = self, values.count >= 2 else {
            return nil
        }
        return Vector2(Float(values[0].doubleValue ?? 0), Float(values[1].doubleValue ?? 0))
    }
}
