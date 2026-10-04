@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorSceneLoadSummary: Equatable, Sendable {
    var entityCount: Int
    var warnings: [String]

    static let empty = Self(entityCount: 0, warnings: [])
}

struct EditorSceneRuntimeLoadResult: Equatable, Sendable {
    var entityCount: Int
    var warnings: [String]
    var entitiesByEditorID: [String: Entity.ID]
    var editorIDsByEntityID: [Entity.ID: String]

    static let empty = Self(entityCount: 0, warnings: [], entitiesByEditorID: [:], editorIDsByEntityID: [:])
}

enum EditorSceneFileLoader {
    static func summary(from content: String) -> EditorSceneLoadSummary {
        do {
            let sceneModel = try EditorSceneModel.decode(from: content)
            return EditorSceneLoadSummary(entityCount: sceneModel.entities.count, warnings: [])
        } catch {
            return EditorSceneLoadSummary(entityCount: 0, warnings: [error.localizedDescription])
        }
    }

    static func model(from content: String) -> EditorSceneModel? {
        try? EditorSceneModel.decode(from: content)
    }

    @discardableResult
    @MainActor
    static func load(
        content: String,
        into world: World,
        loadsScriptableObjects: Bool = true,
        sourceURL: URL? = nil,
        resourceRootURL: URL? = nil
    ) -> EditorSceneRuntimeLoadResult {
        do {
            registerEditorSceneComponents(loadsScriptableObjects: loadsScriptableObjects)
            let sceneModel = try EditorSceneModel.decode(from: content)
            let sourceURL = sourceURL?.resolvingSymlinksInPath().standardizedFileURL
            return instantiate(
                sceneModel,
                in: world,
                loadsScriptableObjects: loadsScriptableObjects,
                sourceURL: sourceURL,
                resourceRootURL: resourceRootURL,
                parentEntity: nil,
                idPrefix: "",
                ancestry: sourceURL.map { Set([$0]) } ?? []
            )
        } catch {
            return .emptyWithWarnings([error.localizedDescription])
        }
    }

    @discardableResult
    @MainActor
    static func load(
        model sceneModel: EditorSceneModel,
        into world: World,
        loadsScriptableObjects: Bool = true,
        sourceURL: URL? = nil,
        resourceRootURL: URL? = nil
    ) -> EditorSceneRuntimeLoadResult {
        registerEditorSceneComponents(loadsScriptableObjects: loadsScriptableObjects)
        let sourceURL = sourceURL?.resolvingSymlinksInPath().standardizedFileURL
        return instantiate(
            sceneModel,
            in: world,
            loadsScriptableObjects: loadsScriptableObjects,
            sourceURL: sourceURL,
            resourceRootURL: resourceRootURL,
            parentEntity: nil,
            idPrefix: "",
            ancestry: sourceURL.map { Set([$0]) } ?? []
        )
    }

    @MainActor
    static func resolvedComponentPayload(
        typeName: String, payload: EditorComponentPayload, sourceURL: URL?, resourceRootURL: URL?
    ) throws -> EditorComponentPayload {
        var resolvedPayload = payload
        if typeName == EditorBuiltInComponentType.model3DSource, let reference = payload["source"]?.stringValue, !reference.isEmpty {
            resolvedPayload["source"] = .string(try EditorModelResource.resolve(reference, sourceURL: sourceURL, resourceRootURL: resourceRootURL).path)
        }
        if typeName == EditorBuiltInComponentType.tileMap,
            let reference = payload["map"]?.stringValue,
            !reference.isEmpty {
            guard let mapURL = resolveTileMapReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL) else {
                throw EditorTileMapReferenceError.invalid(reference)
            }
            let resource = try EditorTileMapResource.read(from: mapURL)
            resolvedPayload.merge(resource.componentPayload) { _, resource in resource }
            if let paths = resource.atlasTextures {
                resolvedPayload["atlasTextures"] = .array(paths.map { path in
                    let url = URL(fileURLWithPath: path, relativeTo: mapURL.deletingLastPathComponent()).standardizedFileURL
                    return .string(url.path)
                })
            }
            if let tileSetReference = resource.tileSetReference {
                let tileSetURL: URL
                if tileSetReference.hasPrefix("@res://"), let resourceRootURL {
                    tileSetURL = resourceRootURL.appendingPathComponent(String(tileSetReference.dropFirst("@res://".count))).standardizedFileURL
                } else {
                    tileSetURL = URL(fileURLWithPath: tileSetReference, relativeTo: mapURL.deletingLastPathComponent()).standardizedFileURL
                }
                let resolvedTileSetURL = tileSetURL.resolvingSymlinksInPath().standardizedFileURL
                if tileSetReference.hasPrefix("@res://"), let resourceRootURL {
                    let rootPath = resourceRootURL.resolvingSymlinksInPath().standardizedFileURL.path
                    guard resolvedTileSetURL.path.hasPrefix(rootPath + "/") else {
                        throw EditorTileMapReferenceError.invalid(tileSetReference)
                    }
                }
                guard resolvedTileSetURL.pathExtension == "tileset", FileManager.default.fileExists(atPath: resolvedTileSetURL.path) else {
                    throw EditorTileMapReferenceError.invalid(tileSetReference)
                }
                resolvedPayload["tileSetReference"] = .string(resolvedTileSetURL.path)
            }
        }
        return resolvedPayload
    }

    @MainActor
    private static func registerEditorSceneComponents(loadsScriptableObjects: Bool) {
        EditorComponentRegistry.registerBuiltIns()
        EditorGizmo.registerComponent()
        if loadsScriptableObjects {
            ScriptableComponents.registerComponent()
        }
    }

    @MainActor
    private static func instantiate(
        _ sceneModel: EditorSceneModel,
        in world: World,
        loadsScriptableObjects: Bool,
        sourceURL: URL?,
        resourceRootURL: URL?,
        parentEntity: Entity?,
        idPrefix: String,
        ancestry: Set<URL>
    ) -> EditorSceneRuntimeLoadResult {
        var warnings: [String] = []
        if world.getResource(UIComponentRuntimeResource.self) == nil {
            let runtime = UIComponentRuntime(resourceRoot: resourceRootURL ?? sourceURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            runtime.enableAdaScript(sourceRoot: EditorSceneViewportView.uiProjectRoot(from: runtime.resources.rootURL))
            world.insertResource(UIComponentRuntimeResource(runtime))
        }
        var entityCount = sceneModel.entities.count
        var entitiesByEditorID: [String: Entity] = [:]
        var runtimeEntityIDsByEditorID: [String: Entity.ID] = [:]
        var editorIDsByRuntimeEntityID: [Entity.ID: String] = [:]

        for sceneEntity in sceneModel.entities {
            let entity = world.spawn(sceneEntity.name)
            entity.isActive = sceneEntity.enabled
            let runtimeEditorID = "\(idPrefix)\(sceneEntity.id)"
            entitiesByEditorID[sceneEntity.id] = entity
            runtimeEntityIDsByEditorID[runtimeEditorID] = entity.id
            editorIDsByRuntimeEntityID[entity.id] = runtimeEditorID

            for (componentName, componentPayload) in sceneEntity.components {
                if componentName == EditorBuiltInComponentType.scriptableComponents, !loadsScriptableObjects {
                    continue
                }
                guard
                    RuntimeTypeRegistry.componentType(named: componentName) != nil
                        || EditorComponentRegistry.descriptor(named: componentName) != nil
                else {
                    warnings.append("Unknown component: \(componentName)")
                    continue
                }

                do {
                    let resolvedPayload = try resolvedComponentPayload(
                        typeName: componentName, payload: componentPayload, sourceURL: sourceURL, resourceRootURL: resourceRootURL
                    )
                    if let component = try EditorComponentRegistry.decode(typeName: componentName, payload: resolvedPayload) {
                        if let ui = (component as? UIComponent) ?? (component as? CompanionPanel)?.ui {
                            let runtime = world.getResource(UIComponentRuntimeResource.self)?.runtime
                            if let source = ui.source {
                                try runtime?.validateScriptBindings(source: source)
                            }
                            // Script values arrive after ready/update. Keep the component until then,
                            // including when an input intentionally has no preview default.
                            if ui.source?.scriptBindings.isEmpty != false {
                                _ = try ui.resolveView(runtime: runtime)
                            }
                        }
                        insertComponent(component, into: entity, in: world)
                    } else {
                        warnings.append("Component is not decodable: \(componentName)")
                    }
                } catch {
                    warnings.append("Failed to decode \(componentName): \(error.localizedDescription)")
                }
            }
            completeRuntimeBundle(for: entity, in: world)
            #if !WASM
            if let reference = entity.components[Model3DSource.self], !reference.source.isEmpty {
                do {
                    let model = try AssetsManager.loadSync(ModelAsset3D.self, at: reference.source)
                    guard let asset = model.asset else { throw AssetError.message("Model has not loaded.") }
                    let root = try reference.instantiate(asset, in: world, under: entity)
                    func registerNodes(_ node: Entity) {
                        entityCount += 1
                        editorIDsByRuntimeEntityID[node.id] = runtimeEditorID
                        for child in node.children { registerNodes(child) }
                    }
                    registerNodes(root)
                } catch {
                    entity.components[Model3DSourceState.self] = .init(reference: reference, error: error.localizedDescription)
                    warnings.append("Failed to load model on \(sceneEntity.name): \(error.localizedDescription)")
                }
            }
            #endif
        }

        for sceneEntity in sceneModel.entities {
            guard let parentID = sceneEntity.parent, !parentID.isEmpty else {
                continue
            }

            guard let entity = entitiesByEditorID[sceneEntity.id] else {
                continue
            }

            guard let parent = entitiesByEditorID[parentID] else {
                warnings.append("Missing parent \(parentID) for entity \(sceneEntity.id)")
                continue
            }

            parent.addChild(entity)
        }

        if let parentEntity {
            for sceneEntity in sceneModel.entities where sceneEntity.parent == nil || sceneEntity.parent?.isEmpty == true {
                if let entity = entitiesByEditorID[sceneEntity.id] {
                    parentEntity.addChild(entity)
                }
            }
        }

        for (editorEntityID, clips) in Dictionary(grouping: sceneModel.animations ?? [], by: \.targetEntityID) {
            guard let entity = entitiesByEditorID[editorEntityID] else {
                warnings.append("Missing animation target \(editorEntityID)")
                continue
            }
            guard let transform = world.get(Transform.self, from: entity.id) else {
                warnings.append("Animation target \(editorEntityID) has no Transform")
                continue
            }
            let runtimeClips = clips.map { $0.makeRuntimeClip(initialTransform: transform) }
            guard !runtimeClips.isEmpty else {
                continue
            }
            world.insert(
                KeyframeAnimator(clips: runtimeClips, initialClipName: runtimeClips.first?.name, isPlaying: true),
                for: entity.id
            )
        }

        let nested = instantiateNestedScenes(
            in: sceneModel,
            entitiesByEditorID: entitiesByEditorID,
            world: world,
            loadsScriptableObjects: loadsScriptableObjects,
            sourceURL: sourceURL,
            resourceRootURL: resourceRootURL,
            idPrefix: idPrefix,
            ancestry: ancestry
        )
        entityCount += nested.entityCount
        warnings.append(contentsOf: nested.warnings)
        for (runtimeID, editorID) in nested.editorIDsByEntityID {
            editorIDsByRuntimeEntityID[runtimeID] = editorID
        }

        return EditorSceneRuntimeLoadResult(
            entityCount: entityCount,
            warnings: warnings,
            entitiesByEditorID: runtimeEntityIDsByEditorID,
            editorIDsByEntityID: editorIDsByRuntimeEntityID
        )
    }

    private static func insertComponent(_ component: any Component, into entity: Entity, in world: World) {
        world.insert(component, for: entity.id)
    }

    @MainActor
    private static func completeRuntimeBundle(for entity: Entity, in world: World) {
        SceneRuntimeBootstrap.prepareCamera(on: entity, in: world)
    }

    @MainActor
    private static func instantiateNestedScenes(
        in sceneModel: EditorSceneModel,
        entitiesByEditorID: [String: Entity],
        world: World,
        loadsScriptableObjects: Bool,
        sourceURL: URL?,
        resourceRootURL: URL?,
        idPrefix: String,
        ancestry: Set<URL>
    ) -> NestedSceneResult {
        var result = NestedSceneResult()
        for sceneEntity in sceneModel.entities {
            guard
                let instancePayload = sceneEntity.components[EditorBuiltInComponentType.sceneInstance],
                let reference = instancePayload["scene"]?.stringValue,
                !reference.isEmpty,
                let instanceEntity = entitiesByEditorID[sceneEntity.id]
            else {
                continue
            }
            guard let nestedURL = resolveSceneReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL) else {
                result.warnings.append("Unable to resolve nested scene \(reference)")
                continue
            }
            guard !ancestry.contains(nestedURL) else {
                result.warnings.append("Nested scene cycle: \(nestedURL.path)")
                continue
            }
            do {
                let nestedModel = try EditorSceneModel.decode(from: String(contentsOf: nestedURL, encoding: .utf8))
                var nestedAncestry = ancestry
                nestedAncestry.insert(nestedURL)
                let runtimeEditorID = "\(idPrefix)\(sceneEntity.id)"
                let nested = instantiate(
                    nestedModel,
                    in: world,
                    loadsScriptableObjects: loadsScriptableObjects,
                    sourceURL: nestedURL,
                    resourceRootURL: resourceRootURL,
                    parentEntity: instanceEntity,
                    idPrefix: "\(runtimeEditorID)/",
                    ancestry: nestedAncestry
                )
                result.entityCount += nested.entityCount
                result.warnings.append(contentsOf: nested.warnings.map { "\(reference): \($0)" })
                for runtimeEntityID in nested.editorIDsByEntityID.keys {
                    result.editorIDsByEntityID[runtimeEntityID] = runtimeEditorID
                }
            } catch {
                result.warnings.append("Failed to load nested scene \(reference): \(error.localizedDescription)")
            }
        }
        return result
    }

    private static func resolveTileMapReference(
        _ reference: String,
        relativeTo sourceURL: URL?,
        resourceRootURL: URL?
    ) -> URL? {
        let root = resourceRootURL ?? sourceURL?.deletingLastPathComponent().deletingLastPathComponent()
        let url: URL
        if reference.hasPrefix("@res://") {
            guard let root else { return nil }
            url = root.appendingPathComponent(String(reference.dropFirst("@res://".count)))
        } else {
            guard let sourceURL else { return nil }
            url = sourceURL.deletingLastPathComponent().appendingPathComponent(reference)
        }
        let resolved = url.resolvingSymlinksInPath().standardizedFileURL
        guard resolved.pathExtension == "tilemap" else { return nil }
        if reference.hasPrefix("@res://"), let root {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.path.hasPrefix(rootPath + "/") else { return nil }
        }
        return resolved
    }

    private static func resolveSceneReference(
        _ reference: String,
        relativeTo sourceURL: URL?,
        resourceRootURL: URL?
    ) -> URL? {
        let trimmed = reference.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let resolvedURL: URL?
        if trimmed.hasPrefix("@res://") {
            guard let resourceRootURL else {
                return nil
            }
            resolvedURL = resourceRootURL.appendingPathComponent(String(trimmed.dropFirst("@res://".count)))
        } else if trimmed.hasPrefix("file://") {
            resolvedURL = URL(string: trimmed)
        } else if trimmed.hasPrefix("/") {
            resolvedURL = URL(fileURLWithPath: trimmed, isDirectory: false)
        } else {
            resolvedURL = sourceURL?.deletingLastPathComponent().appendingPathComponent(trimmed)
        }

        guard let resolvedURL else {
            return nil
        }
        let standardizedURL = resolvedURL.resolvingSymlinksInPath().standardizedFileURL
        if trimmed.hasPrefix("@res://"), let resourceRootURL {
            let root = resourceRootURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard standardizedURL.path == root || standardizedURL.path.hasPrefix("\(root)/") else {
                return nil
            }
        }
        return SceneDocumentFormat.isSceneFile(standardizedURL) ? standardizedURL : nil
    }
}

private struct NestedSceneResult {
    var entityCount = 0
    var warnings: [String] = []
    var editorIDsByEntityID: [Entity.ID: String] = [:]
}

extension EditorSceneRuntimeLoadResult {
    static func emptyWithWarnings(_ warnings: [String]) -> EditorSceneRuntimeLoadResult {
        EditorSceneRuntimeLoadResult(entityCount: 0, warnings: warnings, entitiesByEditorID: [:], editorIDsByEntityID: [:])
    }
}
