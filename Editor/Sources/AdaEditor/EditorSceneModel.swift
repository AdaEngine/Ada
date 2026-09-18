@_spi(AdaEngine) import AdaEngine
import Foundation
import Yams

typealias EditorComponentPayload = [String: EditorSceneValue]

enum EditorSceneEntityPreset: String, CaseIterable, Equatable, Sendable {
    case empty
    case camera
    case sprite
    case light2D

    var title: String {
        switch self {
        case .empty: "Empty Entity"
        case .camera: "Camera"
        case .sprite: "Sprite"
        case .light2D: "Light 2D"
        }
    }
}

enum EditorSceneValue: Codable, Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case uint(UInt64)
    case double(Double)
    case string(String)
    case array([Self])
    case object([String: Self])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .uint(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: Self].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported scene value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch self {
        case .null:
            try container.encodeNil()
        case let .bool(value):
            try container.encode(value)
        case let .int(value):
            try container.encode(value)
        case let .uint(value):
            try container.encode(value)
        case let .double(value):
            try container.encode(value)
        case let .string(value):
            try container.encode(value)
        case let .array(values):
            try container.encode(values)
        case let .object(values):
            try container.encode(values)
        }
    }
}

extension EditorSceneValue {
    var jsonCompatibleValue: Any {
        switch self {
        case .null:
            NSNull()
        case let .bool(value):
            value
        case let .int(value):
            value
        case let .uint(value):
            value
        case let .double(value):
            value
        case let .string(value):
            value
        case let .array(values):
            values.map(\.jsonCompatibleValue)
        case let .object(values):
            values.mapValues(\.jsonCompatibleValue)
        }
    }

    var stringValue: String {
        switch self {
        case .null:
            ""
        case let .bool(value):
            value ? "true" : "false"
        case let .int(value):
            String(value)
        case let .uint(value):
            String(value)
        case let .double(value):
            EditorSceneModelFormatting.format(value)
        case let .string(value):
            value
        case let .array(values):
            values.map(\.stringValue).joined(separator: ", ")
        case let .object(values):
            values
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value.stringValue)" }
                .joined(separator: ", ")
        }
    }

    var doubleValue: Double? {
        switch self {
        case let .int(value):
            Double(value)
        case let .uint(value):
            Double(value)
        case let .double(value):
            value
        case let .string(value):
            Double(value)
        default:
            nil
        }
    }

    var boolValue: Bool? {
        switch self {
        case let .bool(value):
            value
        case .string("true"):
            true
        case .string("false"):
            false
        default:
            nil
        }
    }
}

struct EditorSceneModel: Codable, Equatable, Sendable {
    var format: String
    var schemaVersion: Int
    var engineVersion: String?
    var scene: EditorSceneMetadata
    var entities: [EditorSceneEntity]
    var animations: [EditorAnimationClip]?
    var editor: EditorSceneState?

    init(
        format: String = "ada.scene",
        schemaVersion: Int = 1,
        engineVersion: String? = "1.0.0",
        scene: EditorSceneMetadata,
        entities: [EditorSceneEntity],
        animations: [EditorAnimationClip]? = nil,
        editor: EditorSceneState? = nil
    ) {
        self.format = format
        self.schemaVersion = schemaVersion
        self.engineVersion = engineVersion
        self.scene = scene
        self.entities = entities
        self.animations = animations
        self.editor = editor
    }

    static func decode(from content: String) throws -> Self {
        try YAMLDecoder(encoding: .utf8).decode(Self.self, from: content)
    }

    func encodedYAML() throws -> String {
        try YAMLEncoder().encode(self)
    }

    static func `default`(projectName: String) -> Self {
        let rootID = "root"
        return Self(
            scene: EditorSceneMetadata(id: UUID().uuidString, name: normalizedSceneName(projectName)),
            entities: [
                EditorSceneEntity(
                    id: rootID,
                    name: "Root",
                    enabled: true,
                    parent: nil,
                    components: [
                        EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
                    ]
                )
            ],
            editor: EditorSceneState(
                selectedEntity: rootID,
                expandedEntities: [rootID],
                viewport: [
                    "position": .array([.double(0), .double(0)]),
                    "zoom": .double(1),
                ]
            )
        )
    }

    mutating func addEntity(name: String = "Entity") -> EditorSceneEntity {
        addEntity(name: name, parentID: editor?.selectedEntity)
    }

    mutating func addEntity(name: String, parentID: String?) -> EditorSceneEntity {
        let resolvedParentID = parentID.flatMap { requestedID in
            entities.contains(where: { $0.id == requestedID }) ? requestedID : nil
        }
        let entity = EditorSceneEntity(
            id: UUID().uuidString,
            name: name,
            enabled: true,
            parent: resolvedParentID,
            components: [
                EditorBuiltInComponentType.transform: EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
            ]
        )
        entities.append(entity)
        selectEntity(entity.id)
        return entity
    }

    mutating func addEntity(preset: EditorSceneEntityPreset) -> EditorSceneEntity {
        let template: EditorSceneEntityTemplate =
            switch preset {
            case .empty: .empty
            case .camera: .camera2D
            case .sprite: .sprite
            case .light2D: .light2D
            }
        return addEntity(template: template, parentID: editor?.selectedEntity)
    }

    mutating func addEntity(template: EditorSceneEntityTemplate, parentID: String?) -> EditorSceneEntity {
        let entity = addEntity(name: template.title, parentID: parentID)
        let componentTypes: [String] =
            switch template {
            case .empty,
                .scriptable:
                []
            case .sceneInstance:
                [EditorBuiltInComponentType.sceneInstance]
            case .camera2D,
                .camera3D:
                [EditorBuiltInComponentType.camera, EditorBuiltInComponentType.visibility]
            case .sprite:
                [EditorBuiltInComponentType.sprite]
            case .mesh2D:
                [EditorBuiltInComponentType.mesh2D]
            case .tileMap:
                [EditorBuiltInComponentType.tileMap]
            case .light2D:
                [EditorBuiltInComponentType.light2D]
            case .model3D:
                [EditorBuiltInComponentType.mesh3D]
            case .directionalLight3D:
                [EditorBuiltInComponentType.directionalLight3D]
            case .pointLight3D:
                [EditorBuiltInComponentType.pointLight3D]
            case .spotLight3D:
                [EditorBuiltInComponentType.spotLight3D]
            case .ui:
                [EditorBuiltInComponentType.uiComponent]
            case .physicsBody2D:
                [EditorBuiltInComponentType.physicsBody2D]
            case .physicsBody3D:
                [EditorBuiltInComponentType.physicsBody3D]
            }
        for componentType in componentTypes {
            addComponent(typeName: componentType, to: entity.id)
        }

        guard let entityIndex = entities.firstIndex(where: { $0.id == entity.id }) else {
            return entity
        }
        if template == .scriptable {
            entities[entityIndex].components[EditorBuiltInComponentType.scriptableComponents] = ["scripts": .array([])]
        } else if template == .camera3D {
            entities[entityIndex].components[EditorBuiltInComponentType.camera]?["projection"] = .string("perspective")
            entities[entityIndex].components[EditorBuiltInComponentType.transform]?["position"] = .array([
                .double(0), .double(0), .double(5),
            ])
        }
        return entities[entityIndex]
    }

    mutating func selectEntity(_ entityID: String?) {
        var editor = self.editor ?? EditorSceneState()
        editor.selectedEntity = entityID
        if let entityID {
            for expandedEntityID in expandedEntityIDs(for: entityID) where !editor.expandedEntities.contains(expandedEntityID) {
                editor.expandedEntities.append(expandedEntityID)
            }
        }
        self.editor = editor
    }

    mutating func toggleEntityExpanded(_ entityID: String) {
        var editor = self.editor ?? EditorSceneState()
        if let index = editor.expandedEntities.firstIndex(of: entityID) {
            editor.expandedEntities.remove(at: index)
        } else {
            editor.expandedEntities.append(entityID)
        }
        self.editor = editor
    }

    mutating func addComponent(typeName: String, to entityID: String) {
        guard let entityIndex = entities.firstIndex(where: { $0.id == entityID }) else {
            return
        }

        let descriptor = EditorComponentRegistry.descriptor(named: typeName)
        let requiredTypes = descriptor?.requiredComponentTypeNames ?? []
        for requiredType in requiredTypes where entities[entityIndex].components[requiredType] == nil {
            entities[entityIndex].components[requiredType] = EditorComponentRegistry.defaultPayload(for: requiredType)
        }

        guard entities[entityIndex].components[typeName] == nil else {
            return
        }
        entities[entityIndex].components[typeName] = EditorComponentRegistry.defaultPayload(for: typeName)
    }

    mutating func removeComponent(typeName: String, from entityID: String) {
        guard let entityIndex = entities.firstIndex(where: { $0.id == entityID }) else {
            return
        }
        entities[entityIndex].components[typeName] = nil
    }

    mutating func updateField(typeName: String, field: EditorComponentField, value: String, in entityID: String) {
        guard
            let entityIndex = entities.firstIndex(where: { $0.id == entityID }),
            var payload = entities[entityIndex].components[typeName]
        else {
            return
        }

        if [EditorBuiltInComponentType.physicsBody2D, EditorBuiltInComponentType.physicsBody3D].contains(typeName) {
            payload = EditorComponentRegistry.resolvedPhysicsPayload(payload, is3D: typeName == EditorBuiltInComponentType.physicsBody3D)
        }
        field.write(value, to: &payload)
        entities[entityIndex].components[typeName] = payload
    }

    mutating func addScriptableObject(_ descriptor: EditorScriptableObjectDescriptor, to entityID: String) {
        guard let entityIndex = entities.firstIndex(where: { $0.id == entityID }) else {
            return
        }
        for requiredType in descriptor.requiredComponentTypeNames where entities[entityIndex].components[requiredType] == nil {
            entities[entityIndex].components[requiredType] = EditorComponentRegistry.defaultPayload(for: requiredType)
        }

        var scripts = scriptableObjectValues(in: entities[entityIndex])
        guard !scripts.contains(where: { $0.scriptableObjectIdentifier == descriptor.identifier }) else {
            return
        }
        scripts.append(
            .object([
                "type": .string(descriptor.identifier),
                "version": .int(descriptor.version),
                "payload": .object(Dictionary(uniqueKeysWithValues: descriptor.fields.map { ($0.name, $0.defaultValue) })),
            ])
        )
        entities[entityIndex].components[EditorBuiltInComponentType.scriptableComponents] = ["scripts": .array(scripts)]
    }

    mutating func removeScriptableObject(identifier: String, from entityID: String) {
        guard let entityIndex = entities.firstIndex(where: { $0.id == entityID }) else {
            return
        }
        let scripts = scriptableObjectValues(in: entities[entityIndex])
            .filter {
                $0.scriptableObjectIdentifier != identifier
            }
        if scripts.isEmpty {
            entities[entityIndex].components[EditorBuiltInComponentType.scriptableComponents] = nil
        } else {
            entities[entityIndex].components[EditorBuiltInComponentType.scriptableComponents] = ["scripts": .array(scripts)]
        }
    }

    mutating func updateScriptableObjectField(
        identifier: String,
        field: EditorComponentField,
        value: String,
        in entityID: String
    ) {
        guard let entityIndex = entities.firstIndex(where: { $0.id == entityID }) else {
            return
        }
        var scripts = scriptableObjectValues(in: entities[entityIndex])
        guard
            let scriptIndex = scripts.firstIndex(where: { $0.scriptableObjectIdentifier == identifier }),
            case var .object(script) = scripts[scriptIndex]
        else {
            return
        }
        var payload: EditorComponentPayload
        if case let .object(existingPayload)? = script["payload"] {
            payload = existingPayload
        } else {
            payload = [:]
        }
        field.write(value, to: &payload)
        script["payload"] = .object(payload)
        scripts[scriptIndex] = .object(script)
        entities[entityIndex].components[EditorBuiltInComponentType.scriptableComponents] = ["scripts": .array(scripts)]
    }

    func selectedEntity() -> EditorSceneEntity? {
        guard let selectedEntity = editor?.selectedEntity else {
            return nil
        }
        return entities.first { $0.id == selectedEntity }
    }

    private func scriptableObjectValues(in entity: EditorSceneEntity) -> [EditorSceneValue] {
        guard case let .array(scripts)? = entity.components[EditorBuiltInComponentType.scriptableComponents]?["scripts"] else {
            return []
        }
        return scripts
    }

    private static func normalizedSceneName(_ projectName: String) -> String {
        let trimmed = projectName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Main" : trimmed
    }

    private func expandedEntityIDs(for entityID: String) -> [String] {
        var result: [String] = []
        var nextEntityID: String? = entityID
        var visited: Set<String> = []

        while let currentID = nextEntityID, !visited.contains(currentID) {
            visited.insert(currentID)
            result.append(currentID)
            nextEntityID = entities.first { $0.id == currentID }?.parent
        }

        return result.reversed()
    }
}

extension EditorSceneValue {
    var scriptableObjectIdentifier: String? {
        guard
            case let .object(object) = self,
            case let .string(identifier)? = object["type"]
        else {
            return nil
        }
        return identifier
    }
}

struct EditorSceneMetadata: Codable, Equatable, Sendable {
    var id: String
    var name: String
}

struct EditorSceneEntity: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var enabled: Bool
    var parent: String?
    var components: [String: EditorComponentPayload]
}

struct EditorSceneState: Codable, Equatable, Sendable {
    var selectedEntity: String?
    var expandedEntities: [String]
    var viewport: [String: EditorSceneValue]?

    init(
        selectedEntity: String? = nil,
        expandedEntities: [String] = [],
        viewport: [String: EditorSceneValue]? = nil
    ) {
        self.selectedEntity = selectedEntity
        self.expandedEntities = expandedEntities
        self.viewport = viewport
    }
}

enum EditorSceneModelFormatting {
    static func format(_ value: Double) -> String {
        if value.rounded() == value {
            return String(Int(value))
        }
        return String(format: "%.3f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}
