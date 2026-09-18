import Foundation

enum EditorAgentSceneDeleteChildren: String, Codable, Equatable, Sendable {
    case cascade
    case reparent
}

enum EditorAgentSceneOperation: Codable, Equatable, Sendable {
    case createEntity(id: String?, name: String, parentID: String?, components: [String: EditorComponentPayload])
    case renameEntity(id: String, name: String)
    case setEntityEnabled(id: String, enabled: Bool)
    case reparentEntity(id: String, parentID: String?)
    case deleteEntity(id: String, children: EditorAgentSceneDeleteChildren)
    case setComponent(entityID: String, typeName: String, payload: EditorComponentPayload)
    case removeComponent(entityID: String, typeName: String)
}

struct EditorAgentSceneSnapshot: Equatable, Sendable {
    var relativePath: String
    var revision: String
    var model: EditorSceneModel
}

struct EditorAgentSceneChangeResult: Equatable, Sendable {
    var changeID: String
    var relativePath: String
    var previousRevision: String
    var revision: String
    var model: EditorSceneModel
}

enum EditorAgentSceneToolError: Error, Equatable, LocalizedError, Sendable {
    case invalidScenePath(String)
    case sceneNotFound(String)
    case revisionConflict(expected: String, actual: String)
    case entityNotFound(String)
    case duplicateEntityID(String)
    case invalidEntityName
    case invalidParent(entityID: String, parentID: String)
    case hierarchyCycle(String)
    case componentNotFound(entityID: String, typeName: String)
    case componentUnavailable(String)
    case invalidComponent(typeName: String, message: String)
    case changeNotFound(String)
    case undoConflict(expected: String, actual: String)

    var errorDescription: String? {
        switch self {
        case let .invalidScenePath(path):
            "Invalid project scene path: \(path)"
        case let .sceneNotFound(path):
            "Scene was not found: \(path)"
        case let .revisionConflict(expected, actual):
            "Scene revision conflict. Expected \(expected), found \(actual)."
        case let .entityNotFound(id):
            "Scene entity was not found: \(id)"
        case let .duplicateEntityID(id):
            "Scene entity id already exists: \(id)"
        case .invalidEntityName:
            "Scene entity name must not be empty."
        case let .invalidParent(entityID, parentID):
            "Entity \(entityID) cannot use missing parent \(parentID)."
        case let .hierarchyCycle(entityID):
            "Scene hierarchy contains a cycle at entity \(entityID)."
        case let .componentNotFound(entityID, typeName):
            "Component \(typeName) was not found on entity \(entityID)."
        case let .componentUnavailable(typeName):
            "Component is not available for structured editing: \(typeName)"
        case let .invalidComponent(typeName, message):
            "Invalid \(typeName) component payload: \(message)"
        case let .changeNotFound(id):
            "Scene change was not found: \(id)"
        case let .undoConflict(expected, actual):
            "Scene changed after this operation. Undo expected \(expected), found \(actual)."
        }
    }
}

@MainActor
final class EditorAgentSceneToolService {
    private struct ChangeRecord: Codable {
        var id: String
        var relativePath: String
        var beforeContent: String
        var afterRevision: String
        var createdAt: Date
    }

    private let projectURL: URL
    private let fileManager: FileManager

    init(projectURL: URL, fileManager: FileManager = .default) {
        self.projectURL = projectURL.standardizedFileURL
        self.fileManager = fileManager
    }

    func listScenes() -> [String] {
        guard
            let enumerator = fileManager.enumerator(
                at: projectURL,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        return
            enumerator.compactMap { item -> String? in
                guard
                    let url = item as? URL,
                    Self.sceneExtensions.contains(url.pathExtension.lowercased())
                else {
                    return nil
                }
                return projectRelativePath(for: url)
            }
            .sorted()
    }

    func snapshot(relativePath: String) throws -> EditorAgentSceneSnapshot {
        let sceneURL = try resolvedSceneURL(relativePath)
        guard fileManager.fileExists(atPath: sceneURL.path) else {
            throw EditorAgentSceneToolError.sceneNotFound(relativePath)
        }
        let content = try String(contentsOf: sceneURL, encoding: .utf8)
        return EditorAgentSceneSnapshot(
            relativePath: projectRelativePath(for: sceneURL),
            revision: Self.revision(for: content),
            model: try EditorSceneModel.decode(from: content)
        )
    }

    func apply(
        relativePath: String,
        expectedRevision: String,
        operations: [EditorAgentSceneOperation]
    ) throws -> EditorAgentSceneChangeResult {
        let sceneURL = try resolvedSceneURL(relativePath)
        guard fileManager.fileExists(atPath: sceneURL.path) else {
            throw EditorAgentSceneToolError.sceneNotFound(relativePath)
        }

        let beforeContent = try String(contentsOf: sceneURL, encoding: .utf8)
        let previousRevision = Self.revision(for: beforeContent)
        guard expectedRevision == previousRevision else {
            throw EditorAgentSceneToolError.revisionConflict(expected: expectedRevision, actual: previousRevision)
        }

        var model = try EditorSceneModel.decode(from: beforeContent)
        for operation in operations {
            try apply(operation, to: &model)
        }
        try validateHierarchy(model)
        let afterContent = try model.encodedYAML()
        _ = try EditorSceneModel.decode(from: afterContent)
        let afterRevision = Self.revision(for: afterContent)
        let changeID = UUID().uuidString
        let record = ChangeRecord(
            id: changeID,
            relativePath: projectRelativePath(for: sceneURL),
            beforeContent: beforeContent,
            afterRevision: afterRevision,
            createdAt: Date()
        )

        try afterContent.write(to: sceneURL, atomically: true, encoding: .utf8)
        do {
            try save(record)
        } catch {
            try beforeContent.write(to: sceneURL, atomically: true, encoding: .utf8)
            throw error
        }

        return EditorAgentSceneChangeResult(
            changeID: changeID,
            relativePath: record.relativePath,
            previousRevision: previousRevision,
            revision: afterRevision,
            model: model
        )
    }

    func undo(changeID: String) throws -> EditorAgentSceneSnapshot {
        let recordURL = changesDirectoryURL.appendingPathComponent("\(changeID).json")
        guard fileManager.fileExists(atPath: recordURL.path) else {
            throw EditorAgentSceneToolError.changeNotFound(changeID)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ChangeRecord.self, from: Data(contentsOf: recordURL))
        let sceneURL = try resolvedSceneURL(record.relativePath)
        let currentContent = try String(contentsOf: sceneURL, encoding: .utf8)
        let currentRevision = Self.revision(for: currentContent)
        guard currentRevision == record.afterRevision else {
            throw EditorAgentSceneToolError.undoConflict(expected: record.afterRevision, actual: currentRevision)
        }

        try record.beforeContent.write(to: sceneURL, atomically: true, encoding: .utf8)
        try fileManager.removeItem(at: recordURL)
        return try snapshot(relativePath: record.relativePath)
    }

    private func apply(_ operation: EditorAgentSceneOperation, to model: inout EditorSceneModel) throws {
        switch operation {
        case let .createEntity(requestedID, rawName, parentID, components):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw EditorAgentSceneToolError.invalidEntityName
            }
            if let parentID, !model.entities.contains(where: { $0.id == parentID }) {
                throw EditorAgentSceneToolError.invalidParent(entityID: requestedID ?? "new", parentID: parentID)
            }
            let id = requestedID?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? UUID().uuidString
            guard !model.entities.contains(where: { $0.id == id }) else {
                throw EditorAgentSceneToolError.duplicateEntityID(id)
            }
            var resolvedComponents = components
            if resolvedComponents[EditorBuiltInComponentType.transform] == nil {
                resolvedComponents[EditorBuiltInComponentType.transform] = EditorComponentRegistry.defaultPayload(for: EditorBuiltInComponentType.transform)
            }
            for (typeName, payload) in resolvedComponents {
                try validateComponent(typeName: typeName, payload: payload)
            }
            model.entities.append(EditorSceneEntity(id: id, name: name, enabled: true, parent: parentID, components: resolvedComponents))
            model.selectEntity(id)

        case let .renameEntity(id, rawName):
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                throw EditorAgentSceneToolError.invalidEntityName
            }
            let index = try entityIndex(id, in: model)
            model.entities[index].name = name

        case let .setEntityEnabled(id, enabled):
            let index = try entityIndex(id, in: model)
            model.entities[index].enabled = enabled

        case let .reparentEntity(id, parentID):
            let index = try entityIndex(id, in: model)
            if let parentID, !model.entities.contains(where: { $0.id == parentID }) {
                throw EditorAgentSceneToolError.invalidParent(entityID: id, parentID: parentID)
            }
            model.entities[index].parent = parentID

        case let .deleteEntity(id, children):
            let index = try entityIndex(id, in: model)
            let parentID = model.entities[index].parent
            if children == .cascade {
                let removedIDs = descendantIDs(of: id, in: model).union([id])
                model.entities.removeAll { removedIDs.contains($0.id) }
                model.editor?.expandedEntities.removeAll { removedIDs.contains($0) }
                if let selected = model.editor?.selectedEntity, removedIDs.contains(selected) {
                    model.selectEntity(parentID)
                }
            } else {
                for childIndex in model.entities.indices where model.entities[childIndex].parent == id {
                    model.entities[childIndex].parent = parentID
                }
                model.entities.remove(at: index)
                model.editor?.expandedEntities.removeAll { $0 == id }
                if model.editor?.selectedEntity == id {
                    model.selectEntity(parentID)
                }
            }

        case let .setComponent(entityID, typeName, payload):
            let index = try entityIndex(entityID, in: model)
            try validateComponent(typeName: typeName, payload: payload)
            if model.entities[index].components[typeName] == nil {
                let requiredTypes = EditorComponentRegistry.descriptor(named: typeName)?.requiredComponentTypeNames ?? []
                for requiredType in requiredTypes where model.entities[index].components[requiredType] == nil {
                    model.entities[index].components[requiredType] = EditorComponentRegistry.defaultPayload(for: requiredType)
                }
            }
            model.entities[index].components[typeName] = payload

        case let .removeComponent(entityID, typeName):
            let index = try entityIndex(entityID, in: model)
            guard model.entities[index].components[typeName] != nil else {
                throw EditorAgentSceneToolError.componentNotFound(entityID: entityID, typeName: typeName)
            }
            model.entities[index].components[typeName] = nil
        }
    }

    private func validateComponent(typeName: String, payload: EditorComponentPayload) throws {
        guard EditorComponentRegistry.descriptor(named: typeName) != nil else {
            throw EditorAgentSceneToolError.componentUnavailable(typeName)
        }
        do {
            guard try EditorComponentRegistry.decode(typeName: typeName, payload: payload) != nil else {
                throw EditorAgentSceneToolError.componentUnavailable(typeName)
            }
        } catch let error as EditorAgentSceneToolError {
            throw error
        } catch {
            throw EditorAgentSceneToolError.invalidComponent(typeName: typeName, message: error.localizedDescription)
        }
    }

    private func validateHierarchy(_ model: EditorSceneModel) throws {
        let ids = Set(model.entities.map(\.id))
        guard ids.count == model.entities.count else {
            let duplicate = Dictionary(grouping: model.entities, by: \.id).first { $0.value.count > 1 }?.key ?? "unknown"
            throw EditorAgentSceneToolError.duplicateEntityID(duplicate)
        }

        for entity in model.entities {
            if let parentID = entity.parent, !ids.contains(parentID) {
                throw EditorAgentSceneToolError.invalidParent(entityID: entity.id, parentID: parentID)
            }
            var visited = Set<String>()
            var currentID: String? = entity.id
            while let id = currentID {
                guard visited.insert(id).inserted else {
                    throw EditorAgentSceneToolError.hierarchyCycle(entity.id)
                }
                currentID = model.entities.first { $0.id == id }?.parent
            }
        }
    }

    private func entityIndex(_ id: String, in model: EditorSceneModel) throws -> Int {
        guard let index = model.entities.firstIndex(where: { $0.id == id }) else {
            throw EditorAgentSceneToolError.entityNotFound(id)
        }
        return index
    }

    private func descendantIDs(of entityID: String, in model: EditorSceneModel) -> Set<String> {
        var result = Set<String>()
        var pending = [entityID]
        while let parentID = pending.popLast() {
            for child in model.entities where child.parent == parentID && result.insert(child.id).inserted {
                pending.append(child.id)
            }
        }
        return result
    }

    private func resolvedSceneURL(_ relativePath: String) throws -> URL {
        guard
            !relativePath.hasPrefix("/"),
            Self.sceneExtensions.contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased())
        else {
            throw EditorAgentSceneToolError.invalidScenePath(relativePath)
        }
        let candidate = projectURL.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedProject = projectURL.resolvingSymlinksInPath().path
        let resolvedCandidate = candidate.resolvingSymlinksInPath().path
        guard resolvedCandidate.hasPrefix(resolvedProject + "/") else {
            throw EditorAgentSceneToolError.invalidScenePath(relativePath)
        }
        return candidate
    }

    private func projectRelativePath(for url: URL) -> String {
        String(url.standardizedFileURL.path.dropFirst(projectURL.path.count + 1))
    }

    private func save(_ record: ChangeRecord) throws {
        try fileManager.createDirectory(at: changesDirectoryURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record)
            .write(
                to: changesDirectoryURL.appendingPathComponent("\(record.id).json"),
                options: [.atomic]
            )
    }

    private var changesDirectoryURL: URL {
        projectURL
            .appendingPathComponent(ProjectSystem.metadataDirectoryName, isDirectory: true)
            .appendingPathComponent("workspace/agent/changes", isDirectory: true)
    }

    private static let sceneExtensions: Set<String> = ["ascn", "scene", "scn"]

    private static func revision(for content: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in content.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}

extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
