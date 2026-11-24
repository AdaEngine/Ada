@_spi(AdaEngine) @_spi(Internal) import AdaEngine
import Foundation
import Math

enum EditorCSGScene {
    static let groupType = "AdaStudio.CSGGroup"
    // Retain the original serialized marker for operands in existing scenes.
    static let boxType = "AdaStudio.CSGBox"
    static let checkerTexture = "checker"

    static func shape(of operand: EditorSceneEntity) -> CSGShape? {
        shape(in: operand.components[boxType] ?? [:])
    }

    private static func shape(in payload: EditorComponentPayload) -> CSGShape? {
        guard let raw = payload["shape"] else {
            return .box
        }
        return CSGShape(rawValue: raw.stringValue)
    }

    static func operandSettings(_ payload: EditorComponentPayload) -> (operation: TriangleBooleanOperation, shape: CSGShape)? {
        guard let operation = payload["operation"].flatMap({ TriangleBooleanOperation(rawValue: $0.stringValue) }),
            let shape = shape(in: payload) else {
            return nil
        }
        return (operation, shape)
    }

    static func groupSettings(_ payload: EditorComponentPayload) -> (repeats: Int, texture: String)? {
        guard payload["version"]?.doubleValue == 1,
            let repeats = (payload["uvRepeats"] ?? .int(1)).doubleValue,
            (1...64).contains(repeats),
            repeats.rounded() == repeats else {
            return nil
        }
        let texture: String
        switch payload["texture"] {
        case nil, .some(.null): texture = ""
        case let .some(.string(value)): texture = value
        default: return nil
        }
        guard texture.isEmpty || texture == checkerTexture || supportsTexture(texture) else {
            return nil
        }
        return (Int(repeats), texture)
    }

    static func supportsTexture(_ reference: String) -> Bool {
        reference.hasPrefix("@res://") && ["png", "jpg", "jpeg"].contains(URL(fileURLWithPath: reference).pathExtension.lowercased())
    }

    static func isAuthoringComponent(_ name: String) -> Bool {
        name == groupType || name == boxType
    }

    struct Product: Equatable, Sendable {
        let groupID: String
        let surface: CSGSurface
        let worldMatrix: Transform3D
        let shape: Shape3DResource

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.groupID == rhs.groupID && lhs.surface == rhs.surface && lhs.worldMatrix == rhs.worldMatrix
        }
    }

    struct PreviewTarget: Equatable, Sendable {
        let entityID: Entity.ID
        let source: CSGGroupSource?
    }

    enum Failure: LocalizedError {
        case invalidGroup(String)

        var errorDescription: String? {
            switch self {
            case let .invalidGroup(name): "Invalid CSG geometry in ‘\(name)’."
            }
        }
    }

    /// Used by Play and export so invalid revisions fail before either publishes.
    /// An empty staged scene map limits preparation to the supplied definition.
    @concurrent
    static func prepare(
        _ model: EditorSceneModel,
        sourceURL: URL? = nil,
        resourceRootURL: URL? = nil,
        stagedScenes: [URL: EditorSceneModel]? = nil,
        textureRootURL: URL? = nil
    ) async throws -> [Product] {
        try await prepare(
            model,
            sourceURL: sourceURL,
            resourceRootURL: resourceRootURL,
            prefix: "",
            parentPose: .identity,
            ancestry: sourceURL.map { [$0.resolvingSymlinksInPath().standardizedFileURL] } ?? [],
            stagedScenes: stagedScenes,
            textureRootURL: textureRootURL ?? resourceRootURL
        )
    }

    private static func prepare(
        _ model: EditorSceneModel,
        sourceURL: URL?,
        resourceRootURL: URL?,
        prefix: String,
        parentPose: Transform3D,
        ancestry: Set<URL>,
        stagedScenes: [URL: EditorSceneModel]?,
        textureRootURL: URL?
    ) async throws -> [Product] {
        let entities = Dictionary(model.entities.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var products: [Product] = []
        for entity in model.entities where entity.components[groupType] != nil {
            try Task.checkCancellation()
            do {
                guard let localPose = try activeWorldMatrix(entity, entities: entities) else { continue }
                let pose = localPose.includesRoot ? parentPose * localPose.matrix : localPose.matrix
                let source = try model.csgSource(entity, resourceRootURL: textureRootURL)
                let surface = try await source.evaluate()
                if let shape = try surface.collisionShape(worldMatrix: pose) {
                    try shape.prepareStaticCollision()
                    products.append(.init(groupID: prefix + entity.id, surface: surface, worldMatrix: pose, shape: shape))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                throw Failure.invalidGroup(entity.name)
            }
        }
        if ancestry.count < 64, stagedScenes?.isEmpty != true {
            for entity in model.entities {
                try Task.checkCancellation()
                guard let reference = entity.components[EditorBuiltInComponentType.sceneInstance]?["scene"]?.stringValue,
                    !reference.isEmpty,
                    let url = EditorSceneFileLoader.resolveSceneReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL),
                    !ancestry.contains(url),
                    let pose = try activeWorldMatrix(entity, entities: entities) else { continue }
                let nested: EditorSceneModel?
                if let stagedScenes {
                    nested = stagedScenes[url]
                } else {
                    nested = try? EditorSceneModel.decode(from: String(contentsOf: url, encoding: .utf8))
                }
                guard let nested else {
                    continue
                }
                products += try await prepare(
                    nested,
                    sourceURL: url,
                    resourceRootURL: resourceRootURL,
                    prefix: prefix + entity.id + "/",
                    parentPose: pose.includesRoot ? parentPose * pose.matrix : pose.matrix,
                    ancestry: ancestry.union([url]),
                    stagedScenes: stagedScenes,
                    textureRootURL: textureRootURL
                )
            }
        }
        return products
    }

    @MainActor
    static func install(_ products: [Product], in world: World, result: inout EditorSceneRuntimeLoadResult) {
        guard !products.isEmpty else {
            return
        }
        guard let renderDevice = unsafe RenderEngine.shared?.renderDevice else {
            result.warnings.append(L10n.text("CSG rendering is unavailable."))
            return
        }
        for product in products {
            guard let id = result.csgTargets[product.groupID]?.entityID ?? result.entitiesByEditorID[product.groupID],
                let entity = world.getEntityByID(id) else { continue }
            guard let mesh = product.surface.renderComponent(renderDevice: renderDevice) else { continue }
            let collider = world.spawn("CSG Static Collision")
            collider.components += Transform()
            collider.components += PhysicsBody3DComponent(shapes: [product.shape], mode: .static)
            let rendered = world.spawn("CSG Geometry") {
                Transform()
                mesh
            }
            entity.addChild(rendered)
        }
    }

    private static func activeWorldMatrix(
        _ entity: EditorSceneEntity,
        entities: [String: EditorSceneEntity]
    ) throws -> (matrix: Transform3D, includesRoot: Bool)? {
        var current = entity
        var matrix = Transform3D.identity
        var visited: Set<String> = []
        var inheritsTransform = true
        while true {
            guard visited.insert(current.id).inserted else { throw Failure.invalidGroup(entity.name) }
            guard current.enabled else {
                return nil
            }
            if inheritsTransform {
                if let payload = current.components[EditorBuiltInComponentType.transform] {
                    matrix = try transform(payload).matrix * matrix
                } else {
                    inheritsTransform = false
                }
            }
            guard let id = current.parent, !id.isEmpty else {
                return (matrix, inheritsTransform)
            }
            guard let parent = entities[id] else { throw Failure.invalidGroup(entity.name) }
            current = parent
        }
    }

    static func transform(_ payload: EditorComponentPayload) throws -> Transform {
        try EditorComponentPayloadDecoder.decodeValue(Transform.self, payload: payload)
    }
}

extension EditorSceneModel {
    var hasCSG: Bool { entities.contains { $0.components[EditorCSGScene.groupType] != nil } }
    var requiresCSGPreparation: Bool {
        entities.contains { $0.components[EditorCSGScene.groupType] != nil || $0.components[EditorBuiltInComponentType.sceneInstance] != nil }
    }

    func withoutCSGAuthoring() -> Self {
        guard hasCSG else {
            return self
        }
        var result = self
        let boxes = Set(entities.filter { $0.components[EditorCSGScene.boxType] != nil }.map(\.id))
        result.entities.removeAll { boxes.contains($0.id) }
        for index in result.entities.indices {
            result.entities[index].components[EditorCSGScene.groupType] = nil
        }
        result.animations?.removeAll { boxes.contains($0.targetEntityID) }
        return result
    }

    func csgBoxes(in groupID: String) -> [EditorSceneEntity] {
        entities.filter { $0.parent == groupID && $0.components[EditorCSGScene.boxType] != nil }
    }

    func csgSource(_ entity: EditorSceneEntity, resourceRootURL: URL? = nil) throws -> CSGGroupSource {
        guard let payload = entity.components[EditorCSGScene.groupType], let settings = EditorCSGScene.groupSettings(payload) else {
            throw EditorCSGScene.Failure.invalidGroup(entity.name)
        }
        let boxes = csgBoxes(in: entity.id).filter(\.enabled)
        guard boxes.count <= CSGGroupSource.maximumBoxes else { throw TriangleGeometryError.budgetExceeded }
        let operands = try boxes.map { box -> CSGBoxOperand in
            guard let transform = box.components[EditorBuiltInComponentType.transform],
                let payload = box.components[EditorCSGScene.boxType],
                let settings = EditorCSGScene.operandSettings(payload) else {
                throw EditorCSGScene.Failure.invalidGroup(entity.name)
            }
            return .init(transform: try EditorCSGScene.transform(transform), operation: settings.operation, shape: settings.shape)
        }
        let reference = settings.texture
        let texture: CSGTextureSource?
        switch reference {
        case "": texture = nil
        case EditorCSGScene.checkerTexture: texture = .checker
        default:
            guard let resourceRootURL else {
                throw EditorCSGScene.Failure.invalidGroup(entity.name)
            }
            let root = resourceRootURL.resolvingSymlinksInPath().standardizedFileURL
            let file = root.appendingPathComponent(String(reference.dropFirst("@res://".count))).resolvingSymlinksInPath().standardizedFileURL
            guard file.path.hasPrefix(root.path + "/") else {
                throw EditorCSGScene.Failure.invalidGroup(entity.name)
            }
            let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
            texture = .image(file, modified: modified)
        }
        return .init(boxes: operands, uvRepeats: settings.repeats, texture: texture)
    }

    @discardableResult
    mutating func addCSGBox(to groupID: String, name: String = "CSG Box", shape: CSGShape = .box) -> EditorSceneEntity? {
        guard entities.contains(where: { $0.id == groupID && $0.components[EditorCSGScene.groupType] != nil }),
            csgBoxes(in: groupID).count < CSGGroupSource.maximumBoxes else { return nil }
        _ = addEntity(name: name, parentID: groupID)
        let index = entities.index(before: entities.endIndex)
        entities[index].components[EditorCSGScene.boxType] = ["operation": .string(TriangleBooleanOperation.union.rawValue)]
        if shape != .box {
            entities[index].components[EditorCSGScene.boxType]?["shape"] = .string(shape.rawValue)
        }
        return entities[index]
    }

    mutating func setCSGTexture(_ reference: String, in groupID: String) {
        guard let index = entities.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        entities[index].components[EditorCSGScene.groupType]?["texture"] = reference.isEmpty ? nil : .string(reference)
    }

    mutating func setCSGUVRepeats(_ repeats: Int, in groupID: String) {
        guard (1...64).contains(repeats), let index = entities.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        entities[index].components[EditorCSGScene.groupType]?["uvRepeats"] = repeats == 1 ? nil : .int(repeats)
    }

    mutating func moveCSGBox(_ id: String, in groupID: String, by delta: Int) {
        let indices = entities.indices.filter {
            entities[$0].parent == groupID && entities[$0].components[EditorCSGScene.boxType] != nil
        }
        guard let row = indices.firstIndex(where: { entities[$0].id == id }), indices.indices.contains(row + delta) else {
            return
        }
        entities.swapAt(indices[row], indices[row + delta])
    }

    mutating func setCSGOperation(_ operation: TriangleBooleanOperation, for id: String) {
        guard let index = entities.firstIndex(where: { $0.id == id }),
            entities[index].components[EditorCSGScene.boxType] != nil else { return }
        entities[index].components[EditorCSGScene.boxType]?["operation"] = .string(operation.rawValue)
    }
}
