@_spi(AdaEngine) import AdaEngine
import Foundation

/// The installed authored records are the baseline even while another revision is preparing assets.
@MainActor
final class EditorSceneLiveEdits {
    private struct Record: Equatable {
        var entity: EditorSceneEntity
        var clips: [EditorAnimationClip]
    }

    private struct Revision {
        let model: EditorSceneModel
        var records: [String: Record]
        let children: [String: [String]]

        init(_ model: EditorSceneModel) {
            self.model = model
            let clips = Dictionary(grouping: model.animations ?? [], by: \.targetEntityID)
            self.records = Dictionary(model.entities.map {
                ($0.id, Record(entity: $0, clips: clips[$0.id, default: []]))
            }, uniquingKeysWith: { _, latest in latest })
            self.children = model.entities.reduce(into: [:]) { children, entity in
                if let parent = entity.parent { children[parent, default: []].append(entity.id) }
            }
        }
    }

    private struct ResourceJob {
        let token: UUID
        let references: [String: EditorComponentPayload]
        var task: Task<Void, Never>?
        var assets: EditorSceneAssetCache?
        var warning: String?
    }

    private static let resourceTypes: Set<String> = [
        EditorBuiltInComponentType.model3DSource, EditorBuiltInComponentType.spineSource, EditorBuiltInComponentType.sceneInstance
    ]
    private static let inPlaceTypes: Set<String> = [
        EditorBuiltInComponentType.transform, EditorBuiltInComponentType.visibility,
        EditorBuiltInComponentType.light2D, EditorBuiltInComponentType.lightOccluder2D, EditorBuiltInComponentType.lightModulate2D,
        EditorBuiltInComponentType.directionalLight3D, EditorBuiltInComponentType.pointLight3D, EditorBuiltInComponentType.spotLight3D
    ]

    private var desired: Revision?
    private var installed: [String: Record] = [:]
    private var result: EditorSceneRuntimeLoadResult = .empty
    private var jobs: [String: ResourceJob] = [:]
    private var task: Task<Void, Never>?
    private var generation = 0
    private var needsReconcile = false
    private static let maxAssetJobs = 2

    var isReady: Bool { desired != nil }

    func reset() {
        generation += 1
        task?.cancel()
        task = nil
        for job in jobs.values { job.task?.cancel() }
        jobs.removeAll()
        needsReconcile = false
        desired = nil
        installed.removeAll()
        result = .empty
    }

    func install(_ model: EditorSceneModel, result: EditorSceneRuntimeLoadResult) {
        reset()
        let revision = Revision(model)
        self.result = result
        installed = revision.records
        desired = revision
    }

    func submit(_ model: EditorSceneModel, in viewport: EditorSceneViewportModel) {
        desired = Revision(model)
        schedule(in: viewport)
    }

    func noteTransform(_ payload: EditorComponentPayload, of id: String) {
        let key = EditorBuiltInComponentType.transform
        installed[id]?.entity.components[key] = payload
        desired?.records[id]?.entity.components[key] = payload
    }

    /// Specialized terrain and gesture transactions have already applied their own edits.
    func noteAppliedChanges(in model: EditorSceneModel) {
        guard let desired else {
            return
        }
        let next = Revision(model)
        for (id, record) in next.records {
            guard let before = desired.records[id], var current = installed[id], before != record else { continue }
            for key in Self.changedComponents(before.entity, record.entity) {
                current.entity.components[key] = record.entity.components[key]
            }
            installed[id] = current
        }
        self.desired = next
    }

    private func schedule(in viewport: EditorSceneViewportModel) {
        needsReconcile = true
        guard task == nil else {
            return
        }
        if !viewport.hasHostedSceneApplication {
            needsReconcile = false
            reconcile(in: viewport)
            return
        }
        let generation = generation
        task = Task { [weak self, weak viewport] in
            guard let self, let viewport else {
                return
            }
            do {
                try await viewport.withCSGWorldAccess {
                    guard self.generation == generation else {
                        return
                    }
                    self.needsReconcile = false
                    self.reconcile(in: viewport)
                }
            } catch {
                // The installed world or its viewport was replaced while awaiting access.
            }
            guard self.generation == generation else {
                return
            }
            self.task = nil
            if self.needsReconcile { self.schedule(in: viewport) }
        }
    }

    private func reconcile(in viewport: EditorSceneViewportModel) {
        guard let desired, let world = viewport.world else {
            return
        }
        var assets = world.getResource(EditorSceneAssetCache.self) ?? EditorSceneAssetCache()
        var needsAssetPrune = false
        var refreshCamera = false
        var changed = false
        var relationships: Set<String> = []
        let sliceStart = ContinuousClock.now
        let removed = removalOrder(for: desired)
        for id in jobs.keys.filter({ desired.records[$0] == nil || desired.records[$0] == installed[$0] }) {
            cancelJob(for: id)
        }

        for id in removed {
            if viewport.hasHostedSceneApplication, changed, sliceStart.duration(to: .now) >= .milliseconds(6) {
                needsReconcile = true
                break
            }
            refreshCamera = refreshCamera || installed[id]?.entity.components[EditorBuiltInComponentType.camera] != nil
            installed[id] = nil
            cancelJob(for: id)
            removeRepresentation(id, in: world, relink: &relationships)
            needsAssetPrune = true
            changed = true
        }
        for id in desired.model.entities.map(\.id) {
            guard let next = desired.records[id], installed[id] != next else { continue }
            if viewport.hasHostedSceneApplication, changed, sliceStart.duration(to: .now) >= .milliseconds(6) {
                needsReconcile = true
                break
            }
            let entity = next.entity
            let current = installed[id]
            let runtime = result.entitiesByEditorID[id].flatMap { world.getEntityByID($0) }
            let affectsCamera = entity.components[EditorBuiltInComponentType.camera] != nil
                || current?.entity.components[EditorBuiltInComponentType.camera] != nil
            if let current, let runtime, patch(current, to: next, on: runtime, in: world, loadsPhysics: viewport.liveSceneLoadsPhysics) {
                if current.entity.parent != entity.parent { relationships.insert(id) }
                installed[id] = next
                changed = true
                cancelJob(for: id)
                refreshCamera = refreshCamera || affectsCamera
                continue
            }

            let references = entity.components.filter { Self.resourceTypes.contains($0.key) }
            if !references.isEmpty, viewport.hasHostedSceneApplication {
                ensureResourceJob(for: next, references: references, reusing: assets, in: viewport)
                guard let job = jobs[id], job.references == references, job.task == nil else {
                    if let current, let runtime {
                        let metadataChanged = applyPendingMetadata(current, next: next, to: runtime, in: world, relink: &relationships)
                        changed = changed || metadataChanged
                        refreshCamera = refreshCamera || (affectsCamera && metadataChanged)
                    }
                    continue
                }
                if let prepared = job.assets { assets.mergePrepared(prepared) }
            }
            let local = EditorSceneFileLoader.loadPreviewEntity(
                entity,
                model: desired.model,
                clips: next.clips,
                in: world,
                sourceURL: viewport.liveSceneSourceURL,
                resourceRootURL: viewport.sceneResourceRootURL,
                loadsPhysicsBodies: viewport.liveSceneLoadsPhysics,
                identityNamespace: result.identityNamespace,
                assets: &assets
            )
            removeRepresentation(id, in: world, relink: &relationships)
            result.mergePreviewEntity(local, id: id, preparationWarning: jobs[id]?.warning)
            cancelJob(for: id)
            installed[id] = next
            relationships.insert(id)
            relationships.formUnion(desired.children[id, default: []])
            needsAssetPrune = true
            changed = true
            refreshCamera = refreshCamera || affectsCamera
        }
        for id in relationships {
            guard let record = installed[id], let entity = runtimeEntity(id, in: world) else { continue }
            let parent = record.entity.parent.flatMap { runtimeEntity($0, in: world) }
            if entity.parent !== parent {
                entity.removeFromParent()
                parent?.addChild(entity)
            }
        }
        guard changed else {
            return
        }
        if needsAssetPrune {
            assets.retain(paths: Set(result.assetPathsByEditorID.values.joined()))
            world.insertResource(assets)
        }
        world.flush()
        result.entityCount = result.editorIDsByEntityID.count
        result.warnings = result.warningsByEditorID.keys.sorted().flatMap { result.warningsByEditorID[$0, default: []] }
        viewport.publishLiveSceneEdit(result, in: world, refreshCamera: refreshCamera)
    }

    private func runtimeEntity(_ id: String, in world: World) -> Entity? {
        result.entitiesByEditorID[id].flatMap { world.getEntityByID($0) }
    }

    private func removalOrder(for desired: Revision) -> [String] {
        let removed = installed.keys.filter { desired.records[$0] == nil }
        guard removed.count > 1 else {
            return removed
        }
        let removedIDs = Set(removed)
        // Leave parents available until their removed children have been detached.
        var children: [String: [String]] = [:]
        var roots: [String] = []
        for id in removed {
            if let parent = installed[id]?.entity.parent, removedIDs.contains(parent) {
                children[parent, default: []].append(id)
            } else {
                roots.append(id)
            }
        }
        var visited: Set<String> = []
        var ordered: [String] = []
        for root in roots + removed where !visited.contains(root) {
            var pending = [root]
            var subtree: [String] = []
            while let id = pending.popLast() {
                guard visited.insert(id).inserted else { continue }
                subtree.append(id)
                pending.append(contentsOf: children[id, default: []])
            }
            ordered.append(contentsOf: subtree.reversed())
        }
        return ordered
    }

    private func removeRepresentation(_ id: String, in world: World, relink: inout Set<String>) {
        var removedIDs: Set<Entity.ID> = []
        if let previous = runtimeEntity(id, in: world) {
            for child in previous.children {
                guard let owner = result.editorIDsByEntityID[child.id],
                      result.entitiesByEditorID[owner] == child.id, owner != id else { continue }
                previous.removeChild(child)
                relink.insert(owner)
            }
            var remaining = [previous]
            while let entity = remaining.popLast() {
                guard removedIDs.insert(entity.id).inserted else { continue }
                remaining.append(contentsOf: entity.children)
            }
            previous.removeFromParent()
            world.removeEntity(previous, recursively: true)
        }
        result.removePreviewEntity(id, runtimeIDs: removedIDs)
    }

    private func applyPendingMetadata(_ current: Record, next: Record, to runtime: Entity, in world: World, relink: inout Set<String>) -> Bool {
        guard current.entity.enabled != next.entity.enabled || current.entity.parent != next.entity.parent else {
            return false
        }
        var record = current
        record.entity.enabled = next.entity.enabled
        record.entity.parent = next.entity.parent
        applyVisibility(from: current.entity, to: record.entity, on: runtime, in: world)
        relink.insert(record.entity.id)
        installed[record.entity.id] = record
        return true
    }

    private static func changedComponents(_ before: EditorSceneEntity, _ after: EditorSceneEntity) -> Set<String> {
        Set(before.components.keys).union(after.components.keys).filter { before.components[$0] != after.components[$0] }
    }

    private func patch(_ current: Record, to next: Record, on entity: Entity, in world: World, loadsPhysics: Bool) -> Bool {
        let old = current.entity
        let new = next.entity
        guard old.name == new.name, current.clips == next.clips else {
            return false
        }
        var changed = Self.changedComponents(old, new)
        changed.remove(EditorBuiltInComponentType.scriptableComponents)
        if !loadsPhysics {
            changed.remove(EditorBuiltInComponentType.physicsBody2D)
            changed.remove(EditorBuiltInComponentType.physicsBody3D)
        }
        guard changed.isSubset(of: Self.inPlaceTypes),
              changed.allSatisfy({ old.components[$0] != nil && new.components[$0] != nil }),
              !changed.contains(EditorBuiltInComponentType.transform) || current.clips.isEmpty else {
                  return false
              }
        do {
            // Decode everything first so a failing property cannot leave a partial edit.
            let writes: [any Component] = try changed.map { key in
                guard let payload = new.components[key],
                      let component = try EditorComponentRegistry.decode(typeName: key, payload: payload) else {
                    throw LiveEditError.requiresLoader
                }
                return component
            }
            for component in writes {
                world.insert(component, for: entity.id)
            }
        } catch {
            return false
        }
        applyVisibility(from: old, to: new, on: entity, in: world)
        return true
    }

    private func applyVisibility(from old: EditorSceneEntity, to new: EditorSceneEntity, on entity: Entity, in world: World) {
        let visibility = EditorBuiltInComponentType.visibility
        guard old.enabled != new.enabled || old.components[visibility] != new.components[visibility] else {
            return
        }
        entity.isActive = new.enabled
        if !new.enabled {
            world.insert(Visibility.hidden, for: entity.id)
        } else if !old.enabled {
            let authored = new.components[visibility].flatMap { try? EditorComponentRegistry.decode(typeName: visibility, payload: $0) as? Visibility }
            world.insert(authored ?? .defaultValue, for: entity.id)
        }
    }

    private enum LiveEditError: Error { case requiresLoader }

    private func ensureResourceJob(
        for record: Record,
        references: [String: EditorComponentPayload],
        reusing assets: EditorSceneAssetCache,
        in viewport: EditorSceneViewportModel
    ) {
        let id = record.entity.id
        guard jobs[id]?.references != references, let desired else {
            return
        }
        cancelJob(for: id)
        guard jobs.values.filter({ $0.task != nil }).count < Self.maxAssetJobs else {
            return
        }
        let token = UUID()
        var scope = desired.model
        scope.entities = [record.entity]
        scope.animations = nil
        scope.editor = nil
        let sourceURL = viewport.liveSceneSourceURL
        let rootURL = viewport.sceneResourceRootURL
        let work = Task { [weak self, weak viewport] in
            let preparation: Result<EditorSceneAssetCache, any Error>
            do {
                preparation = .success(try await EditorSceneAssetCache.prepare(
                    model: scope,
                    sourceURL: sourceURL,
                    resourceRootURL: rootURL,
                    reusing: assets
                ))
            } catch {
                preparation = .failure(error)
            }
            guard !Task.isCancelled, let self, let viewport, self.jobs[id]?.token == token else {
                return
            }
            self.jobs[id]?.task = nil
            switch preparation {
            case let .success(prepared): self.jobs[id]?.assets = prepared
            case let .failure(error): self.jobs[id]?.warning = error.localizedDescription
            }
            self.schedule(in: viewport)
        }
        jobs[id] = ResourceJob(token: token, references: references, task: work)
    }

    private func cancelJob(for id: String) {
        jobs.removeValue(forKey: id)?.task?.cancel()
    }
}
