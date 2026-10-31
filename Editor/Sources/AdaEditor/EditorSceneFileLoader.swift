@_spi(AdaEngine) import AdaEngine
import AdaScriptCompilerCore
import AdaSpine
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
        loadsPhysicsBodies: Bool = true,
        sourceURL: URL? = nil,
        resourceRootURL: URL? = nil
    ) -> EditorSceneRuntimeLoadResult {
        do {
            registerEditorSceneComponents(loadsScriptableObjects: loadsScriptableObjects)
            let sceneModel = try EditorSceneModel.decode(from: content)
            let sourceURL = sourceURL?.resolvingSymlinksInPath().standardizedFileURL
            return load(model: sceneModel, into: world, loadsScriptableObjects: loadsScriptableObjects, loadsPhysicsBodies: loadsPhysicsBodies,
                        sourceURL: sourceURL, resourceRootURL: resourceRootURL)
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
        loadsPhysicsBodies: Bool = true,
        sourceURL: URL? = nil,
        resourceRootURL: URL? = nil
    ) -> EditorSceneRuntimeLoadResult {
        registerEditorSceneComponents(loadsScriptableObjects: loadsScriptableObjects)
        let sourceURL = sourceURL?.resolvingSymlinksInPath().standardizedFileURL
        var assets = world.getResource(EditorSceneAssetCache.self) ?? EditorSceneAssetCache()
        assets.beginLoad()
        defer {
            assets.finishLoad()
            world.insertResource(assets)
        }
        return ShaderGraphResourceScope.$rootPath.withValue(resourceRootURL?.path) {
            instantiate(
                sceneModel,
                in: world,
                loadsScriptableObjects: loadsScriptableObjects,
                loadsPhysicsBodies: loadsPhysicsBodies,
                sourceURL: sourceURL,
                resourceRootURL: resourceRootURL,
                parentEntity: nil,
                idPrefix: "",
                ancestry: sourceURL.map { Set([$0]) } ?? [],
                assets: &assets
            )
        }
    }

    @MainActor
    static func resolvedComponentPayload(
        typeName: String, payload: EditorComponentPayload, sourceURL: URL?, resourceRootURL: URL?
    ) throws -> EditorComponentPayload {
        var resolvedPayload = payload
        if typeName == EditorBuiltInComponentType.environment3D {
            let lutPath = ["postProcess", "colorGrading", "lut"]
            var root = EditorSceneValue.object(resolvedPayload)
            if case let .string(reference)? = root.value(at: lutPath[...]), !reference.isEmpty {
                let fileExtension = URL(fileURLWithPath: reference).pathExtension
                guard ["png", "tga", "jpg", "jpeg", "hdr", "tex"].contains(fileExtension.lowercased()),
                    let url = resolveTileMapReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL, fileExtension: fileExtension) else {
                    throw AssetError.message(L10n.text("LUT must be a texture inside project assets."))
                }
                root.setValue(.string(url.path), at: lutPath[...])
                if case let .object(updated) = root { resolvedPayload = updated }
            }
        }
        if typeName == EditorBuiltInComponentType.spineSource, let reference = payload["source"]?.stringValue, !reference.isEmpty {
            resolvedPayload["source"] = .string(try EditorSpineResource.resolve(reference, sourceURL: sourceURL, resourceRootURL: resourceRootURL).path)
        }
        if typeName == EditorBuiltInComponentType.particleEmitter,
            let reference = payload["effect"]?.stringValue, !reference.isEmpty {
            guard let url = resolveTileMapReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL, fileExtension: "particles"),
                url.pathExtension.lowercased() == "particles" else {
                throw AssetError.message("Particle effect must be a .particles resource inside project assets.")
            }
            resolvedPayload["effect"] = .string(url.path)
        }
        if typeName == EditorBuiltInComponentType.spriteAnimator,
            let reference = payload["animations"]?.stringValue, !reference.isEmpty {
            guard let url = resolveTileMapReference(reference, relativeTo: sourceURL, resourceRootURL: resourceRootURL, fileExtension: "spriteanim"),
                url.pathExtension.lowercased() == "spriteanim" else {
                throw AssetError.message("Sprite animation must be a .spriteanim resource inside project assets.")
            }
            resolvedPayload["animations"] = .string(url.path)
        }
        if typeName == EditorBuiltInComponentType.environment3D,
            let reference = payload["imageBasedLightingSource"]?.stringValue, reference.hasPrefix("@res://"), let resourceRootURL {
            let url = resourceRootURL.appendingPathComponent(String(reference.dropFirst(7))).resolvingSymlinksInPath().standardizedFileURL
            let root = resourceRootURL.resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(root.path + "/"), url.pathExtension == "ibl" else {
                throw AssetError.message("Environment must be an IBL asset inside project assets.")
            }
            resolvedPayload["imageBasedLightingSource"] = .string(url.path)
        }
        if typeName == EditorBuiltInComponentType.model3DSource, let reference = payload["source"]?.stringValue, !reference.isEmpty {
            resolvedPayload["source"] = .string(try EditorModelResource.resolve(reference, sourceURL: sourceURL, resourceRootURL: resourceRootURL).path)
            if case var .object(lod) = payload["lod"], case let .array(sources) = lod["sources"] {
                lod["sources"] = .array(try sources.map {
                    .string(try EditorModelResource.resolve($0.stringValue, sourceURL: sourceURL, resourceRootURL: resourceRootURL).path)
                })
                resolvedPayload["lod"] = .object(lod)
            }
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

    /// Installs a prepared preview without holding the UI actor for the whole scene.
    /// The caller suspends this world's hosted updates until installation finishes.
    @MainActor
    static func loadIncrementally(
        model: EditorSceneModel, into world: World, sourceURL: URL?, resourceRootURL: URL?
    ) async throws -> EditorSceneRuntimeLoadResult {
        registerEditorSceneComponents(loadsScriptableObjects: false)
        let sourceURL = sourceURL?.resolvingSymlinksInPath().standardizedFileURL
        var assets = world.getResource(EditorSceneAssetCache.self) ?? EditorSceneAssetCache()
        assets.beginLoad()
        return try await ShaderGraphResourceScope.$rootPath.withValue(resourceRootURL?.path) {
            let state = Instantiation(model, world: world, loadsScriptableObjects: false, loadsPhysicsBodies: false,
                                      sourceURL: sourceURL, resourceRootURL: resourceRootURL, parentEntity: nil,
                                      idPrefix: "", ancestry: sourceURL.map { Set([$0]) } ?? [], assets: assets)
            defer {
                state.assets.finishLoad()
                world.insertResource(state.assets)
            }
            do {
                var batchStart = ContinuousClock.now
                for entity in model.entities {
                    try Task.checkCancellation()
                    state.instantiateEntity(entity)
                    if batchStart.duration(to: .now) >= .milliseconds(8) {
                        world.flush()
                        await Task.yield()
                        batchStart = .now
                    }
                }
                try Task.checkCancellation()
                return state.finish()
            } catch {
                state.removeAll()
                throw error
            }
        }
    }

    @MainActor
    private static func instantiate(
        _ sceneModel: EditorSceneModel,
        in world: World,
        loadsScriptableObjects: Bool,
        loadsPhysicsBodies: Bool,
        sourceURL: URL?,
        resourceRootURL: URL?,
        parentEntity: Entity?,
        idPrefix: String,
        ancestry: Set<URL>,
        assets: inout EditorSceneAssetCache
    ) -> EditorSceneRuntimeLoadResult {
        let state = Instantiation(sceneModel, world: world, loadsScriptableObjects: loadsScriptableObjects,
                                  loadsPhysicsBodies: loadsPhysicsBodies, sourceURL: sourceURL, resourceRootURL: resourceRootURL,
                                  parentEntity: parentEntity, idPrefix: idPrefix, ancestry: ancestry, assets: assets)
        defer { assets = state.assets }
        for entity in sceneModel.entities { state.instantiateEntity(entity) }
        return state.finish()
    }

    @MainActor
    private final class Instantiation {
        let sceneModel: EditorSceneModel
        let world: World
        let loadsScriptableObjects: Bool
        let loadsPhysicsBodies: Bool
        let sourceURL: URL?
        let resourceRootURL: URL?
        let parentEntity: Entity?
        let idPrefix: String
        let ancestry: Set<URL>
        var assets: EditorSceneAssetCache
        var warnings: [String] = []
        var entityCount: Int
        var entitiesByEditorID: [String: Entity] = [:]
        var runtimeEntityIDsByEditorID: [String: Entity.ID] = [:]
        var editorIDsByRuntimeEntityID: [Entity.ID: String] = [:]

        init(_ sceneModel: EditorSceneModel, world: World, loadsScriptableObjects: Bool, loadsPhysicsBodies: Bool,
             sourceURL: URL?, resourceRootURL: URL?, parentEntity: Entity?, idPrefix: String,
             ancestry: Set<URL>, assets: EditorSceneAssetCache) {
            self.sceneModel = sceneModel
            self.world = world
            self.loadsScriptableObjects = loadsScriptableObjects
            self.loadsPhysicsBodies = loadsPhysicsBodies
            self.sourceURL = sourceURL
            self.resourceRootURL = resourceRootURL
            self.parentEntity = parentEntity
            self.idPrefix = idPrefix
            self.ancestry = ancestry
            self.assets = assets
            self.entityCount = sceneModel.entities.count
            if world.getResource(UIComponentRuntimeResource.self) == nil {
                let runtime = UIComponentRuntime(resourceRoot: resourceRootURL ?? sourceURL?.deletingLastPathComponent() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
                runtime.enableAdaScript(sourceRoot: EditorSceneViewportView.uiProjectRoot(from: runtime.resources.rootURL))
                world.insertResource(UIComponentRuntimeResource(runtime))
            }
            for script in EditorScriptComponentStore.shared.components {
                world.registerRuntimeComponent(script.runtime)
            }
        }

        func instantiateEntity(_ sceneEntity: EditorSceneEntity) {
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
                if !loadsPhysicsBodies,
                   componentName == EditorBuiltInComponentType.physicsBody3D || componentName == EditorBuiltInComponentType.physicsBody2D {
                    // The editor renders authored transforms without simulation.
                    // Keep collider geometry in the document/Inspector rather than
                    // decoding a second copy into an unused preview physics body.
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
                    let resolvedPayload = try EditorSceneFileLoader.resolvedComponentPayload(
                        typeName: componentName, payload: componentPayload, sourceURL: sourceURL, resourceRootURL: resourceRootURL
                    )
                    if EditorScriptComponentStore.shared.component(forKey: componentName) != nil {
                        warnings += AdaScriptSceneSchemaResolver.diagnose(
                            key: componentName,
                            fields: resolvedPayload.mapValues(\.jsonCompatibleValue),
                            schemas: EditorScriptComponentStore.shared.schemas,
                            reportsMissingFields: false
                        ).map { "\(sceneEntity.name): \($0.description)" }
                    }
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
                        EditorSceneFileLoader.insertComponent(component, into: entity, in: world)
                    } else {
                        warnings.append("Component is not decodable: \(componentName)")
                    }
                } catch {
                    warnings.append("Failed to decode \(componentName): \(error.localizedDescription)")
                }
            }
            EditorSceneFileLoader.completeRuntimeBundle(for: entity, in: world)
            #if !WASM
            if let reference = entity.components[SpineSource.self], !reference.source.isEmpty {
                do {
                    let skeleton = try assets.skeleton(at: reference.source)
                    try reference.instantiate(skeleton, on: entity)
                } catch {
                    entity.components[SpineSourceState.self] = .init(reference: reference, error: error.localizedDescription)
                    warnings.append("Failed to load Spine on \(sceneEntity.name): \(error.localizedDescription)")
                }
            }
            if let reference = entity.components[Model3DSource.self], !reference.source.isEmpty {
                do {
                    let asset = try assets.model(at: reference.assetPath)
                    let alternatives = try (reference.lod?.sources ?? []).map { source in
                        try assets.model(at: source)
                    }
                    let root = try reference.instantiate(asset, alternatives: alternatives, in: world, under: entity)
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

        func removeAll() {
            for entity in entitiesByEditorID.values { world.removeEntity(entity.id, recursively: true) }
            world.flush()
        }

        func finish() -> EditorSceneRuntimeLoadResult {
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

            let nested = EditorSceneFileLoader.instantiateNestedScenes(
                in: sceneModel,
                entitiesByEditorID: entitiesByEditorID,
                world: world,
                loadsScriptableObjects: loadsScriptableObjects,
                loadsPhysicsBodies: loadsPhysicsBodies,
                sourceURL: sourceURL,
                resourceRootURL: resourceRootURL,
                idPrefix: idPrefix,
                ancestry: ancestry,
                assets: &assets
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
        loadsPhysicsBodies: Bool,
        sourceURL: URL?,
        resourceRootURL: URL?,
        idPrefix: String,
        ancestry: Set<URL>,
        assets: inout EditorSceneAssetCache
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
                    loadsPhysicsBodies: loadsPhysicsBodies,
                    sourceURL: nestedURL,
                    resourceRootURL: resourceRootURL,
                    parentEntity: instanceEntity,
                    idPrefix: "\(runtimeEditorID)/",
                    ancestry: nestedAncestry,
                    assets: &assets
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
        resourceRootURL: URL?,
        fileExtension: String = "tilemap"
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
        guard resolved.pathExtension == fileExtension else { return nil }
        if reference.hasPrefix("@res://") || fileExtension == "particles", let root {
            let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.path.hasPrefix(rootPath + "/") else { return nil }
        }
        return resolved
    }

    static func resolveSceneReference(
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
