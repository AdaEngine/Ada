@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

extension EditorSceneViewportModel {
    func handleMeshTerrainSculptPointer(at point: Point, began: Bool, ended: Bool, cancelled: Bool) -> Bool {
        if cancelled { endTerrainStroke(cancelled: true); return true }
        if terrainEditing.meshSculptPointerActive {
            if !began { recordMeshBrushPoint(point) }
            if ended { endSourceTerrainStroke() }
            return true
        }
        if ended { endSourceTerrainStroke(); return true }
        guard let context = terrainSourceContext, let editorID = selectedEditorID, !terrainEditing.isSourceBusy else { return true }
        if began {
            let tool: EditorMeshTerrainSculptStroke.Tool
            switch (terrainEditing.dockTab, terrainEditing.sourceTool) {
            case ("Sculpt", .sculpt): tool = .shape(terrainEditing.mode)
            case ("Materials", .paint): tool = .material(.paint(layer: terrainEditing.sourceLayerID))
            case ("Materials", .erasePaint): tool = .material(.erase)
            case ("Mesh Instancing", .scatter), ("Mesh Instancing", .eraseMeshes):
                tool = .population(.init(prototypeID: terrainEditing.sourcePrototypeID, density: Float(terrainEditing.meshDensity),
                    seed: terrainEditing.noise.seed, erases: terrainEditing.sourceTool == .eraseMeshes))
            default:
                terrainEditing.sourceStatus = "Choose Sculpt to edit the shape of Mesh Terrain."
                return true
            }
            beginMeshTerrainSculpt(at: point, editorID: editorID, tool: tool, application: context.application, assetsRoot: context.assetsRoot)
        } else {
            terrainEditing.sourceHoverTask?.cancel()
            terrainEditing.sourceHoverTask = Task { @MainActor [weak self] in
                guard let self else { return }
                let hit = try? await context.application.withWorldAccess { self.meshTerrainSculptHit(at: point, editorID: editorID) }
                guard !Task.isCancelled, !self.terrainEditing.isSourceBusy, self.selectedEditorID == editorID, self.terrainEditing.usesBrush else { return }
                self.terrainEditing.hover = hit.map { .init(editorID: $0.editorID, point: $0.sample.position, matrix: $0.matrix, queries: $0.surface.queries) }
                self.terrainEditing.brushRevision &+= 1
            }
        }
        return true
    }

    func updateMeshTerrainSculpt(deltaTime: Float) -> Bool {
        guard !terrainEditing.sourceReleaseRequested, let stroke = terrainEditing.meshSculptStroke else { return false }
        if consumeMeshBrushPoints(stroke) { return true }
        guard let point = terrainEditing.pointer, let sample = meshTerrainSample(at: point, matrix: stroke.hit.matrix, queries: stroke.hit.surface.queries) else {
            return false
        }
        stroke.append(sample, duration: deltaTime)
        terrainEditing.hover = .init(editorID: stroke.hit.editorID, point: sample.position, matrix: stroke.hit.matrix, queries: stroke.previewQueries)
        terrainEditing.brushRevision &+= 1
        return true
    }

    private func recordMeshBrushPoint(_ point: Point) {
        guard point.x.isFinite, point.y.isFinite,
            (terrainEditing.meshBrushPoints.last ?? terrainEditing.meshBrushLastPoint) != point else { return }
        // Keep the most recent position even if a burst fills the bounded buffer.
        if terrainEditing.meshBrushPoints.count == 64 { terrainEditing.meshBrushPoints[63] = point }
        else { terrainEditing.meshBrushPoints.append(point) }
    }

    @discardableResult
    private func consumeMeshBrushPoints(_ stroke: EditorMeshTerrainSculptStroke) -> Bool {
        guard !terrainEditing.meshBrushPoints.isEmpty else { return false }
        let path = terrainEditing.meshBrushPoints
        terrainEditing.meshBrushPoints.removeAll(keepingCapacity: true)
        var budget = 128, consumed = 0
        var lastHit: TerrainSurfaceQueryHit?
        for point in path {
            guard budget > 0, !stroke.exceededLimit else { break }
            consumed += 1
            let start = terrainEditing.meshBrushLastPoint ?? point
            terrainEditing.meshBrushLastPoint = point
            let dx = point.x - start.x, dy = point.y - start.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length.isFinite else { continue }
            let end = meshTerrainSample(at: point, matrix: stroke.hit.matrix, queries: stroke.hit.surface.queries)
            let startHit = meshTerrainSample(at: start, matrix: stroke.hit.matrix, queries: stroke.hit.surface.queries)
            let worldLength = end.flatMap { end in startHit.map { ($0.position - end.position).length } } ?? 0
            let stride = max(0.05, stroke.radiusForSampling * 0.25)
            let steps = min(budget, max(1, Int(min(64, ceil(max(length / 16, worldLength / stride))))))
            budget -= steps
            for index in 1...steps {
                let t = Float(index) / Float(steps)
                let screen = Point(x: start.x + dx * t, y: start.y + dy * t)
                let sample = index == steps ? end : meshTerrainSample(at: screen, matrix: stroke.hit.matrix, queries: stroke.hit.surface.queries)
                if let sample { stroke.append(sample, duration: 1 / 60); lastHit = sample }
            }
        }
        if consumed < path.count, !stroke.exceededLimit {
            terrainEditing.meshBrushPoints = Array(path.dropFirst(consumed))
        }
        terrainEditing.hover = lastHit.map { .init(editorID: stroke.hit.editorID, point: $0.position, matrix: stroke.hit.matrix, queries: stroke.previewQueries) }
        terrainEditing.brushRevision &+= 1
        return true
    }

    private func beginMeshTerrainSculpt(at point: Point, editorID: String, tool: EditorMeshTerrainSculptStroke.Tool,
                                       application: AppWorlds, assetsRoot: URL) {
        guard let baseline = sceneModel else { return }
        let radius = terrainEditing.radius, strength = terrainEditing.strength, tab = terrainEditing.dockTab
        let generation = UUID()
        terrainEditing.sourceGeneration = generation
        terrainEditing.sourceHoverTask?.cancel()
        terrainEditing.sourceReleaseRequested = false
        terrainEditing.meshSculptPointerActive = true
        terrainEditing.meshBrushLastPoint = point
        terrainEditing.meshBrushPoints.removeAll(keepingCapacity: true)
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceStatus = "Drawing mesh terrainâ€¦"
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSourceTerrainTask(generation: generation) }
            let isCurrent = {
                self.terrainEditing.sourceGeneration == generation && self.terrainEditing.usesBrush && self.terrainEditing.dockTab == tab
                    && self.selectedEditorID == editorID && self.matchesMeshTerrainSculptModel(baseline)
                    && self.terrainSourceContext?.application === application && self.terrainSourceContext?.assetsRoot == assetsRoot
            }
            var captured: EditorMeshTerrainSculptStroke?
            do {
                let stroke = try await application.withWorldAccess {
                    guard isCurrent(), let hit = self.meshTerrainSculptHit(at: point, editorID: editorID) else {
                        throw EditorTerrainSourceAuthoring.Failure.unavailable
                    }
                    _ = try EditorTerrainResource.resolve(hit.source.source, sourceURL: assetsRoot.appendingPathComponent("scene.ascn"), resourceRootURL: assetsRoot)
                    if case let .material(operation) = tool {
                        guard let palette = hit.owner.components[MeshTerrain3DSourceResources.self]?.manifest.materials else {
                            throw EditorTerrainSourceAuthoring.Failure.unavailable
                        }
                        if case let .paint(layer) = operation, !palette.layers.contains(where: { $0.id == layer }) {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                    }
                    if case let .population(settings) = tool,
                        hit.owner.components[MeshTerrain3DSourceResources.self]?.manifest.meshPrototypes.contains(where: { $0.id == settings.prototypeID }) != true {
                        throw TerrainInstanceBrushError.missingPrototype
                    }
                    let ownership = try MeshTerrain3DOwnership.capture(of: hit.owner, in: application.main)
                    return try EditorMeshTerrainSculptStroke(hit: hit, ownership: ownership, radius: radius, strength: strength, tool: tool)
                }
                captured = stroke
                try Task.checkCancellation()
                self.terrainEditing.meshSculptStroke = stroke
                stroke.append(stroke.hit.sample, duration: 1 / 60)
                let resident = try await self.previewMeshTerrainSculpt(stroke, application: application, isCurrent: isCurrent)
                guard resident.compiled?.inputKey != stroke.hit.surface.asset.compiled?.inputKey else { return }
                let input = EditorMeshTerrainTransaction.Input(owner: stroke.hit.owner, original: stroke.hit.source, previous: resident, candidate: resident,
                    previousOwnership: stroke.ownership, draws: stroke.ownership.draws, collisions: stroke.ownership.collisions,
                    bindings: [], previousBindings: [], rollbackAsset: stroke.hit.surface.asset)
                try await EditorMeshTerrainTransaction.run(input, application: application, isCurrent: isCurrent,
                    onProgress: { self.terrainEditing.sourceStatus = $0 }, commit: { file in
                        guard isCurrent(), let index = self.sceneModel?.entities.firstIndex(where: { $0.id == editorID }) else {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                        let root = assetsRoot.resolvingSymlinksInPath().standardizedFileURL.path
                        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
                        guard path.hasPrefix(root + "/") else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                        self.sceneModel?.entities[index].components[EditorBuiltInComponentType.terrain3DSource]?["source"] = .string("@res://" + path.dropFirst(root.count + 1))
                        self.publishTerrainDocument()
                        self.refreshTerrainSourceControls()
                    })
            } catch {
                if let captured, self.matchesMeshTerrainSculptModel(baseline) {
                    let failure = await Task { @MainActor () -> String? in
                        do {
                            _ = try await captured.publish(captured.hit.surface.asset, application: application, isCurrent: {
                                self.matchesMeshTerrainSculptModel(baseline) && self.terrainSourceContext?.application === application
                            })
                            return nil
                        } catch { return error.localizedDescription }
                    }.value
                    if let failure, self.terrainEditing.meshSculptStroke === captured, self.matchesMeshTerrainSculptModel(baseline) {
                        self.terrainEditing.sourceStatus = "Mesh Terrain could not be restored. The last valid surface is still visible."
                        self.terrainEditing.sourceFailure = failure
                    }
                }
                if !(error is CancellationError), self.terrainEditing.sourceFailure == nil, self.terrainEditing.sourceGeneration == generation {
                    self.terrainEditing.sourceStatus = "Mesh Terrain could not be updated."
                    self.terrainEditing.sourceFailure = error.localizedDescription
                }
            }
        }
    }

    private func previewMeshTerrainSculpt(_ stroke: EditorMeshTerrainSculptStroke, application: AppWorlds,
                                         isCurrent: () -> Bool) async throws -> MeshTerrainDocumentAsset {
        var revision: UInt64 = 0
        var accepted = stroke.hit.surface.asset
        while true {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            consumeMeshBrushPoints(stroke)
            if stroke.exceededLimit { throw EditorTerrainSourceAuthoring.Failure.failed("Split this brush stroke into smaller strokes.") }
            if revision != stroke.revision {
                let requested = stroke.revision
                let resident = try await stroke.publish(stroke.candidate(), application: application, isCurrent: isCurrent)
                accepted = resident.asset
                stroke.previewQueries = resident.queries
                revision = requested
                terrainEditing.brushRevision &+= 1
            }
            if terrainEditing.sourceReleaseRequested, revision == stroke.revision, terrainEditing.meshBrushPoints.isEmpty { return accepted }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private func matchesMeshTerrainSculptModel(_ baseline: EditorSceneModel) -> Bool {
        var current = sceneModel, expected = baseline
        current?.editor = nil; expected.editor = nil
        return current == expected
    }

    private func meshTerrainSculptHit(at point: Point, editorID: String) -> EditorMeshTerrainSculptStroke.Hit? {
        guard !isPerspectiveTransitionActive, let owner = runtimeEntity(for: editorID), let source = owner.components[Terrain3DSource.self],
            let surface = owner.components[MeshTerrain3DSourceSurface.self], let matrix = EditorPicking.worldMatrix(for: owner, requiringVisible: true),
            let sample = meshTerrainSample(at: point, matrix: matrix, queries: surface.queries) else { return nil }
        return .init(editorID: editorID, owner: owner, source: source, surface: surface, matrix: matrix, sample: sample)
    }

    private func meshTerrainSample(at point: Point, matrix: Transform3D, queries: TerrainSurfaceQueries?) -> TerrainSurfaceQueryHit? {
        let camera = cameraState(for: viewportSize)
        guard let queries, let ray = EditorPicking.ray(point: point, viewportSize: viewportSize, cameraTransform: camera.transform.matrix,
            projection: camera.projection.makeClipView()), let local = EditorPicking.localRay(ray, matrix: matrix) else { return nil }
        return try? queries.raycast(local)
    }
}
