@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

extension EditorTerrainEditingState {
    struct SourceHit {
        let editorID: String
        let ownerID: Entity.ID
        let payload: EditorComponentPayload
        var surface: Terrain3DSourceSurface
        let revision: UInt64
        let matrix: Transform3D
        var point: Vector3
    }
    struct SourceStroke {
        var hit: SourceHit
        let command: EditorTerrainStrokeCommand
        var points: [TerrainBrushPoint]
        var time: Double = 0
    }
}

extension EditorSceneViewportModel {
    func handleSourceTerrainPointer(at point: Point, began: Bool, ended: Bool, cancelled: Bool) -> Bool {
        guard terrainEditing.stroke == nil,
              terrainEditing.isSourceBusy || sceneModel?.entities.contains(where: { $0.components[EditorBuiltInComponentType.terrain3DSource] != nil }) == true else {
            return false
        }
        if cancelled {
            endSourceTerrainStroke(cancelled: true)
            return true
        }
        if ended {
            endSourceTerrainStroke()
            return true
        }
        guard let context = terrainSourceContext else {
            return false
        }
        if began {
            guard !terrainEditing.isSourceBusy else {
                return true
            }
            terrainEditing.sourceHoverTask?.cancel()
            terrainEditing.sourceGeneration = UUID()
            let generation = terrainEditing.sourceGeneration
            terrainEditing.isSourceBusy = true
            terrainEditing.sourceReleaseRequested = false
            terrainEditing.sourceStatus = "Preparing terrain stroke…"
            terrainEditing.sourceTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                defer { self.finishSourceTerrainTask(generation: generation) }
                do {
                    let hit = try await context.application.withWorldAccess { self.preferredSourceTerrainHit(at: point) }
                    guard !Task.isCancelled, self.terrainEditing.sourceGeneration == generation else {
                        return
                    }
                    guard let hit else {
                        let released = self.terrainEditing.sourceReleaseRequested
                        self.terrainEditing.isSourceBusy = false
                        _ = self.handleLegacyTerrainPointer(at: point, began: true)
                        if released { self.endTerrainStroke() }
                        return
                    }
                    self.terrainEditing.sourceManifest = hit.surface.manifest
                    let command = self.makeTerrainSourceCommand(at: hit.point)
                    let lastPoint = self.terrainEditing.pointer.flatMap { self.sourceTerrainPoint(at: $0, hit: hit) } ?? hit.point
                    self.terrainEditing.sourceStroke = .init(
                        hit: hit,
                        command: command,
                        points: [.init(position: hit.point, time: 0), .init(position: lastPoint, time: 1 / 60)],
                        time: 1 / 60
                    )
                    _ = self.updateSourceTerrainStroke(deltaTime: 1 / 60)
                    if command.changesResource {
                        while !self.terrainEditing.sourceReleaseRequested {
                            try Task.checkCancellation()
                            try await Task.sleep(for: .milliseconds(16))
                        }
                    }
                    try await self.runTerrainSourceCommand(command, hit: hit, generation: generation, live: !command.changesResource)
                } catch is CancellationError {
                } catch {
                    if self.terrainEditing.sourceGeneration == generation {
                        self.terrainEditing.sourceStatus = "Terrain stroke could not be saved. Try again."
                    }
                }
            }
        } else if !terrainEditing.isSourceBusy {
            terrainEditing.sourceHoverTask?.cancel()
            terrainEditing.sourceHoverTask = Task { @MainActor [weak self] in
                guard let self else {
                    return
                }
                let hit = try? await context.application.withWorldAccess { self.preferredSourceTerrainHit(at: point) }
                guard !Task.isCancelled, !self.terrainEditing.isSourceBusy else {
                    return
                }
                self.terrainEditing.hover = hit.map { .init(editorID: $0.editorID, point: $0.point, matrix: $0.matrix, storage: $0.surface.storage, queries: $0.surface.queries) }
                    ?? self.terrainHit(at: point, lockedTo: nil)
                self.terrainEditing.brushRevision &+= 1
            }
        }
        return true
    }

    func updateSourceTerrainStroke(deltaTime: Float) -> Bool {
        guard !terrainEditing.sourceReleaseRequested, var stroke = terrainEditing.sourceStroke,
              let pointer = terrainEditing.pointer, deltaTime.isFinite, deltaTime > 0, stroke.points.count < 4_096,
              let point = sourceTerrainPoint(at: pointer, hit: stroke.hit) else {
            return false
        }
        stroke.time += Double(min(deltaTime, 0.05))
        stroke.points.append(.init(position: point, time: stroke.time))
        terrainEditing.sourceStroke = stroke
        terrainEditing.hover = .init(
            editorID: stroke.hit.editorID,
            point: point,
            matrix: stroke.hit.matrix,
            storage: stroke.hit.surface.storage,
            queries: stroke.hit.surface.queries
        )
        terrainEditing.brushRevision &+= 1
        return true
    }

    func endSourceTerrainStroke(cancelled: Bool = false) {
        guard cancelled else {
            terrainEditing.sourceReleaseRequested = true
            return
        }
        terrainEditing.meshHistoryQueue.cancel()
        terrainEditing.sourceGeneration = UUID()
        let generation = terrainEditing.sourceGeneration
        terrainEditing.sourceTask?.cancel()
        terrainEditing.sourceHoverTask?.cancel()
        terrainEditing.sourceStroke = nil
        terrainEditing.sourceReleaseRequested = true
        if let task = terrainEditing.sourceTask {
            terrainEditing.sourceTask = Task { @MainActor [weak self] in
                await task.value
                self?.finishSourceTerrainTask(generation: generation)
            }
        } else {
            finishSourceTerrainTask(generation: generation)
        }
    }

    func runTerrainSourceCommand(_ command: EditorTerrainStrokeCommand, hit: EditorTerrainEditingState.SourceHit, generation: UUID, live: Bool = false) async throws {
        guard let context = terrainSourceContext else { throw EditorTerrainSourceAuthoring.Failure.unavailable }
        let owner = try await context.application.withWorldAccess {
            guard let owner = context.application.main.getEntityByID(hit.ownerID) else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
            return owner
        }
        let brush = TerrainHeightBrushStroke(settings: .init(operation: .raise), points: [.init(position: hit.point, time: 0), .init(position: hit.point, time: 1 / 60)])
        _ = try await EditorTerrainSourceAuthoring.applyHeightStroke(
            to: owner,
            application: context.application,
            expectedStorage: hit.surface.storage,
            expectedRevision: hit.revision,
            brush: brush,
            command: command,
            assetsRoot: context.assetsRoot,
            isCurrent: { [weak self] in self?.isCurrentSourceStroke(hit, generation: generation) == true },
            onProgress: { [weak self] phase in
                guard let self, self.terrainEditing.sourceGeneration == generation else {
                    return
                }
                switch phase {
                case .preparing: self.terrainEditing.sourceStatus = "Preparing terrain stroke…"
                case .applying: self.terrainEditing.sourceStatus = "Drawing terrain…"
                case .saving, .writing: self.terrainEditing.sourceStatus = "Saving terrain stroke…"
                }
            },
            commit: { [weak self] fork in
                guard let self, self.isCurrentSourceStroke(hit, generation: generation),
                      let index = self.sceneModel?.entities.firstIndex(where: { $0.id == hit.editorID }) else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                let root = context.assetsRoot.resolvingSymlinksInPath().standardizedFileURL
                let path = fork.resolvingSymlinksInPath().standardizedFileURL.path
                guard path.hasPrefix(root.path + "/") else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                self.sceneModel?.entities[index].components[EditorBuiltInComponentType.terrain3DSource]?["source"] = .string("@res://" + path.dropFirst(root.path.count + 1))
                self.publishTerrainDocument()
                self.refreshTerrainSourceControls()
                if let model = self.sceneModel { self.onSelectionChanged?(self.selectedEntityViewModel(editorID: self.selectedEditorID, model: model)) }
            },
            nextCommand: live ? { [weak self] in
                guard let self, var stroke = self.terrainEditing.sourceStroke else {
                    return (nil, true)
                }
                guard stroke.points.count >= 2 else {
                    return (nil, self.terrainEditing.sourceReleaseRequested)
                }
                let points = Array(stroke.points.prefix(256))
                stroke.points.removeFirst(points.count - 1)
                self.terrainEditing.sourceStroke = stroke
                return (self.terrainCommand(stroke.command, with: points), false)
            } : nil,
            onPublished: { [weak self] surface in
                self?.terrainEditing.sourceStroke?.hit.surface = surface
                self?.terrainEditing.brushRevision &+= 1
            }
        )
    }

    private func terrainCommand(_ command: EditorTerrainStrokeCommand, with points: [TerrainBrushPoint]) -> EditorTerrainStrokeCommand {
        switch command {
        case let .height(value): .height(.init(settings: value.settings, points: points))
        case let .surface(value): .surface(.init(settings: value.settings, points: points))
        case let .instances(value): .instances(.init(settings: value.settings, points: points))
        default: command
        }
    }

    private func isCurrentSourceStroke(_ hit: EditorTerrainEditingState.SourceHit, generation: UUID) -> Bool {
        terrainEditing.sourceGeneration == generation && terrainEditing.usesBrush && displayMode == .threeD
            && entitiesByEditorID[hit.editorID] == hit.ownerID
            && sceneModel?.entities.first(where: { $0.id == hit.editorID })?.components[EditorBuiltInComponentType.terrain3DSource] == hit.payload
    }

    func finishSourceTerrainTask(generation: UUID) {
        guard terrainEditing.sourceGeneration == generation else {
            return
        }
        terrainEditing.sourceTask = nil
        terrainEditing.sourceStroke = nil
        terrainEditing.meshSculptPointerActive = false
        terrainEditing.meshBrushPoints.removeAll(keepingCapacity: true)
        terrainEditing.meshBrushLastPoint = nil
        terrainEditing.meshSculptStroke = nil
        terrainEditing.isSourceBusy = false
        if terrainEditing.sourceFailure == nil, terrainEditing.sourceStatus != "Terrain stroke could not be saved. Try again." { terrainEditing.sourceStatus = nil }
    }

    private func preferredSourceTerrainHit(at point: Point) -> EditorTerrainEditingState.SourceHit? {
        guard let source = sourceTerrainHit(at: point) else {
            return nil
        }
        guard let legacy = terrainHit(at: point, lockedTo: nil) else {
            return source
        }
        let camera = cameraState(for: viewportSize)
        let sourceWorld = (source.matrix * Vector4(source.point, 1)).xyz
        let legacyWorld = (legacy.matrix * Vector4(legacy.point, 1)).xyz
        return (legacyWorld - camera.transform.position).squaredLength < (sourceWorld - camera.transform.position).squaredLength ? nil : source
    }

    func terrainSourceEntity(for editorID: String?) -> EditorSceneEntity? {
        guard let editorID else { return nil }
        return sceneModel?.entities.first { $0.id == editorID && $0.components[EditorBuiltInComponentType.terrain3DSource] != nil }
    }

    func isMeshTerrainSource(for editorID: String?) -> Bool {
        guard let entity = terrainSourceEntity(for: editorID) else { return false }
        if let owner = runtimeEntity(for: entity.id) {
            if owner.components[MeshTerrain3DSourceSurface.self] != nil { return true }
            if owner.components[Terrain3DSourceSurface.self] != nil { return false }
        }
        return entity.components[String(reflecting: MeshTerrain3DIdentity.self)] != nil
    }

    func selectedTerrainSourceHit(for editorID: String?) -> EditorTerrainEditingState.SourceHit? {
        guard let model = sceneModel, let world else {
            return nil
        }
        // An explicit terrain selection owns the command even while loading or
        // when its backend cannot use the heightfield tool.
        let entities = terrainSourceEntity(for: editorID).map { [$0] } ?? model.entities
        for entity in entities where entity.enabled {
            guard let payload = entity.components[EditorBuiltInComponentType.terrain3DSource], let id = entitiesByEditorID[entity.id],
                  let owner = world.getEntityByID(id), let surface = owner.components[Terrain3DSourceSurface.self],
                    let matrix = EditorPicking.worldMatrix(for: owner, requiringVisible: true) else { continue }
            return .init(editorID: entity.id, ownerID: id, payload: payload, surface: surface, revision: surface.storage.revision, matrix: matrix, point: .zero)
        }
        return nil
    }

    private func sourceTerrainHit(at point: Point) -> EditorTerrainEditingState.SourceHit? {
        guard let model = sceneModel, let world, !isPerspectiveTransitionActive else {
            return nil
        }
        let camera = cameraState(for: viewportSize)
        guard let ray = EditorPicking.ray(point: point, viewportSize: viewportSize, cameraTransform: camera.transform.matrix, projection: camera.projection.makeClipView()) else {
            return nil
        }
        var best: EditorTerrainEditingState.SourceHit?
        var distance = Double.infinity
        for entity in model.entities where entity.enabled {
            guard let payload = entity.components[EditorBuiltInComponentType.terrain3DSource],
                  let id = entitiesByEditorID[entity.id], let owner = world.getEntityByID(id),
                    let surface = owner.components[Terrain3DSourceSurface.self], let queries = surface.queries,
                  let matrix = EditorPicking.worldMatrix(for: owner, requiringVisible: true), let local = EditorPicking.localRay(ray, matrix: matrix),
                  let hit = try? queries.raycast(local),
                  surface.storage.height(at: Vector2(hit.position.x, hit.position.z)) != nil else { continue }
            let direction = (matrix.inverse * Vector4(ray.direction, 0)).xyz
            let length = (Double(direction.x) * Double(direction.x) + Double(direction.y) * Double(direction.y) + Double(direction.z) * Double(direction.z)).squareRoot()
            let worldDistance = hit.preciseDistance / length
            guard length.isFinite, length > 0, worldDistance < distance else { continue }
            distance = worldDistance
            best = .init(editorID: entity.id, ownerID: id, payload: payload, surface: surface, revision: surface.storage.revision, matrix: matrix, point: hit.position)
        }
        return best
    }

    private func sourceTerrainPoint(at point: Point, hit: EditorTerrainEditingState.SourceHit) -> Vector3? {
        let camera = cameraState(for: viewportSize)
        guard let ray = EditorPicking.ray(point: point, viewportSize: viewportSize, cameraTransform: camera.transform.matrix, projection: camera.projection.makeClipView()),
              let local = EditorPicking.localRay(ray, matrix: hit.matrix), let queries = hit.surface.queries,
              let next = try? queries.raycast(local) else {
            return nil
        }
        return next.position
    }
}
