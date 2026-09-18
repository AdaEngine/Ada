import Foundation

extension EditorSceneModel {
    mutating func addSceneInstance(parentID: String?) -> EditorSceneEntity {
        let entity = addEntity(name: "Scene Prefab", parentID: parentID)
        addComponent(typeName: EditorBuiltInComponentType.sceneInstance, to: entity.id)
        return entities.first { $0.id == entity.id } ?? entity
    }

    var rootEntityID: String? {
        entities.first(where: { $0.parent == nil })?.id
    }

    func isRootEntity(_ entityID: String) -> Bool {
        rootEntityID == entityID
    }

    mutating func renameEntity(_ entityID: String, to rawName: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard
            !name.isEmpty,
            let index = entities.firstIndex(where: { $0.id == entityID })
        else {
            return false
        }
        entities[index].name = name
        return true
    }

    mutating func setEntityEnabled(_ entityID: String, isEnabled: Bool) -> Bool {
        guard let index = entities.firstIndex(where: { $0.id == entityID }) else {
            return false
        }
        entities[index].enabled = isEnabled
        return true
    }

    mutating func deleteEntity(_ entityID: String) -> Bool {
        guard
            !isRootEntity(entityID),
            let entity = entities.first(where: { $0.id == entityID })
        else {
            return false
        }

        let removedIDs = Set(subtreeEntityIDs(rootedAt: entityID))
        guard !removedIDs.isEmpty else {
            return false
        }
        entities.removeAll { removedIDs.contains($0.id) }

        var editor = self.editor ?? EditorSceneState()
        editor.expandedEntities.removeAll { removedIDs.contains($0) }
        if let selectedEntity = editor.selectedEntity, removedIDs.contains(selectedEntity) {
            editor.selectedEntity = entity.parent ?? rootEntityID
        }
        self.editor = editor
        return true
    }

    mutating func duplicateEntity(_ entityID: String) -> EditorSceneEntity? {
        guard
            !isRootEntity(entityID),
            let entity = entities.first(where: { $0.id == entityID })
        else {
            return nil
        }
        let sourceEntities = subtreeEntityIDs(rootedAt: entityID)
            .compactMap { sourceID in
                entities.first(where: { $0.id == sourceID })
            }
        return cloneSubtree(
            sourceEntities,
            rootEntityID: entityID,
            parentID: entity.parent,
            rootName: uniqueCopyName(for: entity.name, parentID: entity.parent)
        )
    }

    func clipboardPayload(for entityID: String) -> String? {
        let copiedEntities = subtreeEntityIDs(rootedAt: entityID)
            .compactMap { sourceID in
                entities.first(where: { $0.id == sourceID })
            }
        guard !copiedEntities.isEmpty else {
            return nil
        }
        let payload = EditorSceneEntityClipboardPayload(rootEntityID: entityID, entities: copiedEntities)
        guard
            let data = try? JSONEncoder().encode(payload),
            let json = String(bytes: data, encoding: .utf8)
        else {
            return nil
        }
        return EditorSceneEntityClipboardPayload.prefix + json
    }

    static func canPasteEntityPayload(_ value: String) -> Bool {
        decodeClipboardPayload(value) != nil
    }

    mutating func pasteEntity(from value: String, parentID: String?) -> EditorSceneEntity? {
        guard
            let payload = Self.decodeClipboardPayload(value),
            let sourceRoot = payload.entities.first(where: { $0.id == payload.rootEntityID })
        else {
            return nil
        }
        let resolvedParentID = parentID.flatMap { requestedID in
            entities.contains(where: { $0.id == requestedID }) ? requestedID : nil
        }
        return cloneSubtree(
            payload.entities,
            rootEntityID: payload.rootEntityID,
            parentID: resolvedParentID,
            rootName: uniqueCopyName(for: sourceRoot.name, parentID: resolvedParentID)
        )
    }

    func canReparentEntity(_ entityID: String, to parentID: String) -> Bool {
        guard
            entityID != parentID,
            !isRootEntity(entityID),
            entities.contains(where: { $0.id == entityID }),
            entities.contains(where: { $0.id == parentID })
        else {
            return false
        }
        return !Set(subtreeEntityIDs(rootedAt: entityID)).contains(parentID)
    }

    mutating func reparentEntity(_ entityID: String, to parentID: String) -> Bool {
        guard
            canReparentEntity(entityID, to: parentID),
            let index = entities.firstIndex(where: { $0.id == entityID })
        else {
            return false
        }
        entities[index].parent = parentID
        var editor = self.editor ?? EditorSceneState()
        if !editor.expandedEntities.contains(parentID) {
            editor.expandedEntities.append(parentID)
        }
        self.editor = editor
        selectEntity(entityID)
        return true
    }
}

extension EditorSceneModel {
    private func subtreeEntityIDs(rootedAt rootID: String) -> [String] {
        guard entities.contains(where: { $0.id == rootID }) else {
            return []
        }
        let childrenByParent = Dictionary(grouping: entities) { $0.parent }
        var result: [String] = []
        var visited: Set<String> = []

        func append(_ entityID: String) {
            guard visited.insert(entityID).inserted else {
                return
            }
            result.append(entityID)
            for child in childrenByParent[entityID] ?? [] {
                append(child.id)
            }
        }

        append(rootID)
        return result
    }

    private mutating func cloneSubtree(
        _ sourceEntities: [EditorSceneEntity],
        rootEntityID: String,
        parentID: String?,
        rootName: String
    ) -> EditorSceneEntity? {
        let sourceIDs = Set(sourceEntities.map(\.id))
        guard
            sourceIDs.count == sourceEntities.count,
            sourceIDs.contains(rootEntityID),
            sourceEntities.allSatisfy({ entity in
                entity.id == rootEntityID || entity.parent.map(sourceIDs.contains) == true
            })
        else {
            return nil
        }

        let idMapping = Dictionary(uniqueKeysWithValues: sourceEntities.map { ($0.id, UUID().uuidString) })
        let clonedEntities = sourceEntities.compactMap { source -> EditorSceneEntity? in
            guard let clonedID = idMapping[source.id] else {
                return nil
            }
            var clone = source
            clone.id = clonedID
            clone.parent = source.id == rootEntityID ? parentID : source.parent.flatMap { idMapping[$0] }
            if source.id == rootEntityID {
                clone.name = rootName
            }
            return clone
        }
        guard
            clonedEntities.count == sourceEntities.count,
            let clonedRootID = idMapping[rootEntityID],
            let clonedRoot = clonedEntities.first(where: { $0.id == clonedRootID })
        else {
            return nil
        }

        entities.append(contentsOf: clonedEntities)
        if let parentID {
            var editor = self.editor ?? EditorSceneState()
            if !editor.expandedEntities.contains(parentID) {
                editor.expandedEntities.append(parentID)
            }
            self.editor = editor
        }
        selectEntity(clonedRootID)
        return clonedRoot
    }

    private func uniqueCopyName(for sourceName: String, parentID: String?) -> String {
        let baseName = sourceName.hasSuffix(" Copy") ? sourceName : "\(sourceName) Copy"
        let siblingNames = Set(entities.filter { $0.parent == parentID }.map(\.name))
        guard siblingNames.contains(baseName) else {
            return baseName
        }
        var suffix = 2
        while siblingNames.contains("\(baseName) \(suffix)") {
            suffix += 1
        }
        return "\(baseName) \(suffix)"
    }

    private static func decodeClipboardPayload(_ value: String) -> EditorSceneEntityClipboardPayload? {
        guard value.hasPrefix(EditorSceneEntityClipboardPayload.prefix) else {
            return nil
        }
        let json = String(value.dropFirst(EditorSceneEntityClipboardPayload.prefix.count))
        guard
            let data = json.data(using: .utf8),
            let payload = try? JSONDecoder().decode(EditorSceneEntityClipboardPayload.self, from: data),
            payload.version == EditorSceneEntityClipboardPayload.currentVersion,
            isValidClipboardSubtree(payload)
        else {
            return nil
        }
        return payload
    }

    private static func isValidClipboardSubtree(_ payload: EditorSceneEntityClipboardPayload) -> Bool {
        let entityIDs = Set(payload.entities.map(\.id))
        guard
            entityIDs.count == payload.entities.count,
            entityIDs.contains(payload.rootEntityID),
            payload.entities.allSatisfy({ entity in
                entity.id == payload.rootEntityID || entity.parent.map(entityIDs.contains) == true
            })
        else {
            return false
        }

        let childrenByParent = Dictionary(grouping: payload.entities) { $0.parent }
        var visited: Set<String> = []
        func visit(_ entityID: String) {
            guard visited.insert(entityID).inserted else {
                return
            }
            for child in childrenByParent[entityID] ?? [] {
                visit(child.id)
            }
        }
        visit(payload.rootEntityID)
        return visited == entityIDs
    }
}

private struct EditorSceneEntityClipboardPayload: Codable, Sendable {
    static let currentVersion = 1
    static let prefix = "adaeditor.scene-entities.v1\n"

    var version = currentVersion
    var rootEntityID: String
    var entities: [EditorSceneEntity]
}
