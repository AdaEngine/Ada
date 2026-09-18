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
                    if let component = try EditorComponentRegistry.decode(typeName: componentName, payload: componentPayload) {
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
        guard let camera = world.get(Camera.self, from: entity.id) else {
            return
        }
        if world.get(Visibility.self, from: entity.id) == nil {
            world.insert(Visibility.visible, for: entity.id)
        }
        if world.get(VisibleEntities.self, from: entity.id) == nil {
            world.insert(VisibleEntities(), for: entity.id)
        }
        if world.get(GlobalViewUniform.self, from: entity.id) == nil {
            world.insert(GlobalViewUniform(), for: entity.id)
        }
        if world.get(AudioReceiver.self, from: entity.id) == nil {
            world.insert(AudioReceiver(), for: entity.id)
        }
        if world.get(CameraRenderGraph.self, from: entity.id) == nil {
            let renderGraph: CameraRenderGraph
            switch camera.projection {
            case .perspective:
                renderGraph = CameraRenderGraph(subgraphLabel: .main3D, inputSlot: Core3DPlugin.InputNode.view)
            case .orthographic,
                .custom:
                renderGraph = CameraRenderGraph(subgraphLabel: .main2D, inputSlot: Main2DRenderNode.InputNode.view)
            }
            world.insert(renderGraph, for: entity.id)
        }
        if case .perspective = camera.projection,
            world.get(Environment3D.self, from: entity.id) == nil {
            world.insert(Environment3D(), for: entity.id)
        }
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
