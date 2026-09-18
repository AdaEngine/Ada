@_spi(AdaEngine) import AdaEngine
import Foundation
import Yams

enum EditorSceneYAMLDocument {
    enum Error: Swift.Error, Equatable, LocalizedError {
        case invalidRoot
        case missingEntities
        case missingEntity(String)
        case invalidComponents(String)

        var errorDescription: String? {
            switch self {
            case .invalidRoot:
                return "Scene YAML root is not a mapping"
            case .missingEntities:
                return "Scene YAML does not contain an entities array"
            case let .missingEntity(entityID):
                return "Scene YAML does not contain entity \(entityID)"
            case let .invalidComponents(entityID):
                return "Scene entity \(entityID) has invalid components"
            }
        }
    }

    static let transformComponentName = String(reflecting: Transform.self)
    static let editorGizmoComponentName = String(reflecting: EditorGizmo.self)

    static func upsertTransform(_ transform: Transform, entityID: String, in content: String) throws -> String {
        try updateEntity(entityID: entityID, in: content) { entity in
            try setComponentPayload(transformPayload(transform), componentName: transformComponentName, entity: &entity, entityID: entityID)
        }
    }

    static func upsertGizmo(_ gizmo: EditorGizmo, entityID: String, in content: String) throws -> String {
        try updateEntity(entityID: entityID, in: content) { entity in
            try setComponentPayload(gizmoPayload(gizmo), componentName: editorGizmoComponentName, entity: &entity, entityID: entityID)
        }
    }

    static func componentPayload(named componentName: String, entityID: String, in content: String) throws -> [String: Any]? {
        let root = try sceneRoot(from: content)
        guard let entities = root["entities"] as? [[String: Any]] else {
            throw Error.missingEntities
        }
        guard let entity = entities.first(where: { $0["id"] as? String == entityID }) else {
            throw Error.missingEntity(entityID)
        }
        guard let components = entity["components"] as? [String: Any] else {
            return nil
        }
        return components[componentName] as? [String: Any]
    }

    private static func updateEntity(
        entityID: String,
        in content: String,
        update: (inout [String: Any]) throws -> Void
    ) throws -> String {
        var root = try sceneRoot(from: content)
        guard var entities = root["entities"] as? [[String: Any]] else {
            throw Error.missingEntities
        }
        guard let index = entities.firstIndex(where: { $0["id"] as? String == entityID }) else {
            throw Error.missingEntity(entityID)
        }

        var entity = entities[index]
        try update(&entity)
        entities[index] = entity
        root["entities"] = entities

        return try dump(object: root, sortKeys: false)
    }

    private static func sceneRoot(from content: String) throws -> [String: Any] {
        guard let root = try Yams.load(yaml: content) as? [String: Any] else {
            throw Error.invalidRoot
        }
        return root
    }

    private static func setComponentPayload(
        _ payload: [String: Any],
        componentName: String,
        entity: inout [String: Any],
        entityID: String
    ) throws {
        if entity["components"] == nil {
            entity["components"] = [String: Any]()
        }
        guard var components = entity["components"] as? [String: Any] else {
            throw Error.invalidComponents(entityID)
        }

        components[componentName] = payload
        entity["components"] = components
    }

    private static func transformPayload(_ transform: Transform) -> [String: Any] {
        [
            "position": [transform.position.x, transform.position.y, transform.position.z],
            "rotation": [transform.rotation.x, transform.rotation.y, transform.rotation.z, transform.rotation.w],
            "scale": [transform.scale.x, transform.scale.y, transform.scale.z],
        ]
    }

    private static func gizmoPayload(_ gizmo: EditorGizmo) -> [String: Any] {
        var payload: [String: Any] = [
            "name": gizmo.name,
            "kind": gizmo.kind.rawValue,
            "isEnabled": gizmo.isEnabled,
            "size": gizmo.size,
        ]
        if let color = gizmo.color {
            payload["color"] = [
                "red": color.red,
                "green": color.green,
                "blue": color.blue,
                "alpha": color.alpha,
            ]
        }
        return payload
    }
}
