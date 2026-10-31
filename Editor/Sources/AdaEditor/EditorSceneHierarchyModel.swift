import AdaUtils
import Foundation

struct EditorSceneHierarchyItem: Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var level: Int
    var isEnabled: Bool
    var isSelected: Bool
    var isExpanded: Bool
    var hasChildren: Bool
    var componentNames: [String]
    var resources: [EditorSceneHierarchyResource]
}

struct EditorSceneHierarchyResource: Equatable, Sendable {
    var componentName: String
    var fieldName: String
    var value: String
}

enum EditorSceneHierarchyModel {
    /// Label-only panels can omit resource discovery, which walks arbitrary component payloads.
    static func visibleItems(for model: EditorSceneModel, query: String = "", includesResources: Bool = true) -> [EditorSceneHierarchyItem] {
        let span = AdaTrace.startSpan("AdaEditor.SceneHierarchy.rows")
        defer { span.end() }
        let entitiesByID = Dictionary(uniqueKeysWithValues: model.entities.map { ($0.id, $0) })
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var includedIDs = Set<String>()
        if !search.isEmpty {
            for entity in model.entities where entity.name.localizedStandardContains(search) {
                var current: EditorSceneEntity? = entity
                var ancestors = Set<String>()
                while let value = current, ancestors.insert(value.id).inserted {
                    includedIDs.insert(value.id)
                    current = value.parent.flatMap { entitiesByID[$0] }
                }
            }
        }
        let expandedEntityIDs = search.isEmpty ? Set(model.editor?.expandedEntities ?? []) : includedIDs
        let selectedEntityID = model.editor?.selectedEntity
        let entities = search.isEmpty ? model.entities : model.entities.filter { includedIDs.contains($0.id) }
        let childrenByParentID = Dictionary(grouping: entities) { entity in
            entity.parent.flatMap { entitiesByID[$0] == nil ? nil : $0 }
        }
        let rootEntities = childrenByParentID[nil] ?? []

        var items: [EditorSceneHierarchyItem] = []
        var visited: Set<String> = []
        for entity in rootEntities {
            append(
                entity,
                level: 0,
                childrenByParentID: childrenByParentID,
                expandedEntityIDs: expandedEntityIDs,
                selectedEntityID: selectedEntityID,
                includesResources: includesResources,
                visited: &visited,
                items: &items
            )
        }

        return items
    }

    static func shortComponentName(_ componentName: String) -> String {
        componentName.components(separatedBy: ".").last ?? componentName
    }
}

extension EditorSceneHierarchyModel {
    private static func append(
        _ entity: EditorSceneEntity,
        level: Int,
        childrenByParentID: [String?: [EditorSceneEntity]],
        expandedEntityIDs: Set<String>,
        selectedEntityID: String?,
        includesResources: Bool,
        visited: inout Set<String>,
        items: inout [EditorSceneHierarchyItem]
    ) {
        guard !visited.contains(entity.id) else {
            return
        }

        visited.insert(entity.id)
        let children = childrenByParentID[entity.id] ?? []
        let isExpanded = expandedEntityIDs.contains(entity.id)
        items.append(
            EditorSceneHierarchyItem(
                id: entity.id,
                name: entity.name,
                level: level,
                isEnabled: entity.enabled,
                isSelected: entity.id == selectedEntityID,
                isExpanded: isExpanded,
                hasChildren: !children.isEmpty,
                componentNames: entity.components.keys.sorted().map(shortComponentName),
                resources: includesResources ? resources(from: entity) : []
            )
        )

        guard isExpanded else {
            return
        }

        for child in children {
            append(
                child,
                level: level + 1,
                childrenByParentID: childrenByParentID,
                expandedEntityIDs: expandedEntityIDs,
                selectedEntityID: selectedEntityID,
                includesResources: includesResources,
                visited: &visited,
                items: &items
            )
        }
    }

    private static func resources(from entity: EditorSceneEntity) -> [EditorSceneHierarchyResource] {
        var resources: [EditorSceneHierarchyResource] = []
        var seen: Set<String> = []

        for typeName in entity.components.keys.sorted() {
            guard let payload = entity.components[typeName] else {
                continue
            }

            let componentName = shortComponentName(typeName)
            if let descriptor = EditorComponentRegistry.descriptor(named: typeName) {
                for field in descriptor.fields where field.kind == .assetReference || field.kind == .sceneReference {
                    appendResource(
                        componentName: componentName,
                        fieldName: field.label,
                        value: field.displayValue(in: payload),
                        seen: &seen,
                        resources: &resources
                    )
                }
            }

            appendResources(
                in: payload,
                componentName: componentName,
                resourceKey: false,
                seen: &seen,
                resources: &resources
            )
        }

        return resources
    }

    // Numeric geometry can contain millions of values. Carry only the resource
    // hint and leaf label; constructing a path/index string for every coordinate
    // made mounting the hierarchy block the editor's main actor.
    private enum ResourceFieldName {
        case key(String)
        case index(Int)

        var text: String {
            switch self {
            case let .key(key): key
            case let .index(index): String(index)
            }
        }
    }

    private static func appendResources(
        in payload: EditorComponentPayload,
        componentName: String,
        resourceKey: Bool,
        seen: inout Set<String>,
        resources: inout [EditorSceneHierarchyResource]
    ) {
        for key in payload.keys.sorted() {
            guard let value = payload[key] else { continue }
            switch value {
            case .string, .array, .object: break
            default: continue
            }
            appendResources(
                in: value,
                componentName: componentName,
                fieldName: .key(key),
                resourceKey: resourceKey || keyLooksResourceLike(key),
                seen: &seen,
                resources: &resources
            )
        }
    }

    private static func appendResources(
        in value: EditorSceneValue,
        componentName: String,
        fieldName: ResourceFieldName,
        resourceKey: Bool,
        seen: inout Set<String>,
        resources: inout [EditorSceneHierarchyResource]
    ) {
        switch value {
        case let .string(string):
            guard resourceKey || valueLooksResourceLike(string) else {
                return
            }
            appendResource(
                componentName: componentName,
                fieldName: fieldName.text,
                value: string,
                seen: &seen,
                resources: &resources
            )
        case let .array(values):
            for (index, value) in values.enumerated() {
                switch value {
                case .string, .array, .object: break
                default: continue
                }
                appendResources(
                    in: value,
                    componentName: componentName,
                    fieldName: .index(index),
                    resourceKey: resourceKey,
                    seen: &seen,
                    resources: &resources
                )
            }
        case let .object(values):
            appendResources(in: values, componentName: componentName, resourceKey: resourceKey,
                seen: &seen, resources: &resources)
        case .bool,
            .double,
            .int,
            .uint,
            .null:
            break
        }
    }

    private static func appendResource(
        componentName: String,
        fieldName: String,
        value: String,
        seen: inout Set<String>,
        resources: inout [EditorSceneHierarchyResource]
    ) {
        let trimmedValue = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedValue.isEmpty else {
            return
        }

        let key = "\(componentName).\(fieldName).\(trimmedValue)".lowercased()
        guard !seen.contains(key) else {
            return
        }

        seen.insert(key)
        resources.append(
            EditorSceneHierarchyResource(
                componentName: componentName,
                fieldName: fieldName,
                value: trimmedValue
            )
        )
    }

    private static let resourceTerms = ["asset", "resource", "texture", "material", "mesh", "audio", "path", "file", "url"]

    private static func keyLooksResourceLike(_ key: String) -> Bool {
        let lowercased = key.lowercased()
        return resourceTerms.contains { lowercased.contains($0) }
    }

    private static func valueLooksResourceLike(_ value: String) -> Bool {
        let lowercasedValue = value.lowercased()
        let resourceExtensions = [
            ".ascn", ".atlas", ".dae", ".fbx", ".glb", ".gltf", ".jpg", ".jpeg", ".json", ".material", ".mp3", ".obj", ".png", ".scene", ".scn",
            ".shader", ".wav", ".yaml", ".yml",
        ]
        return lowercasedValue.hasPrefix("assets/")
            || lowercasedValue.hasPrefix("res://")
            || resourceExtensions.contains { lowercasedValue.hasSuffix($0) }
    }
}
