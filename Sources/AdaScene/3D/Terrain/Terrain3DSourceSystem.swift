import AdaECS
@_spi(Internal) import AdaPhysics
@_spi(Internal) import AdaRender
import AdaTransform
import Foundation
import Math

/// Loads terrain references and maintains generated tile geometry beneath their authored owners.
@PlainSystem
public struct Terrain3DSourceSystem {
    @Query<Entity, Terrain3DSource> private var sources
    @Query<Entity, Camera> private var cameras
    @Query<Entity, PhysicsBody3DComponent, Transform> private var bodies
    @FilterQuery<Entity, CharacterController3DComponent, Transform, Without<PhysicsBody3DComponent>> private var characters
    @Query<Entity, TerrainSourceState> private var instances
    @Query<Entity, Terrain3DHeightEdit> private var heightEdits
    @Query<Entity, MeshTerrain3DEdit> private var meshEdits
    @Query<Entity, Terrain3DSave> private var saves
    @Query<Entity, Terrain3DSaveStatus> private var saveStatuses
    @Res<Physics3DWorldHolder?> private var physicsWorld
    @Res<FixedTime?> private var fixedTime
    @Local private var saveQueue = TerrainSourceSaveQueue()
    @Local private var ownedSources: Set<Entity.ID> = []
    @Local private var jobs: [Entity.ID: TerrainSourceJob] = [:]
    @Local private var waiting: [Entity.ID] = []
    @Local private var waitingSet: Set<Entity.ID> = []
    @Commands private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        guard sources.first != nil || instances.first != nil || heightEdits.first != nil || meshEdits.first != nil || saves.first != nil || !ownedSources.isEmpty || !jobs.isEmpty || saveQueue.hasJobs else {
            return
        }
        for id in jobs.keys.filter({ jobs[$0]?.isFinished == true }) { jobs.removeValue(forKey: id) }
        var sourceKeys: [Entity.ID: TerrainSourceKey] = [:]
        sources.forEach { entity, source in sourceKeys[entity.id] = TerrainSourceKey(source) }
        var saveRequests: [Entity.ID: Terrain3DSave] = [:]
        saves.forEach { entity, request in saveRequests[entity.id] = request }
        let saveQueue = saveQueue
        saveQueue.reconcile(sources: sourceKeys, requests: saveRequests.mapValues(\.id))
        var states: [Entity.ID: TerrainSourceState] = [:]
        instances.forEach { entity, state in states[entity.id] = state }
        let acknowledging = saveQueue.drain(states: states, busy: Set(jobs.keys), commands: commands.queue)
        saveStatuses.forEach { entity, status in
            guard status.phase == .pending, saveRequests[entity.id]?.id != status.id,
                states[entity.id]?.saveJob?.request.id != status.id, !saveQueue.contains(status.id)
            else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSaveStatus.self]?.id == status.id,
                    owner.components[Terrain3DSave.self]?.id != status.id
                else {
                    return
                }
                owner.components[Terrain3DSaveStatus.self] = .init(id: status.id, phase: .cancelled, savedRevision: nil, error: nil)
            }
        }
        let cameraPositions = activeCameraPositions()
        let physicsBounds = TerrainPhysicsBounds.collect(bodies: bodies, characters: characters, physics: physicsWorld, deltaTime: fixedTime?.deltaTime ?? 0)
        var live: Set<Entity.ID> = []
        var edits: [Entity.ID: Terrain3DHeightEdit] = [:]
        heightEdits.forEach { entity, edit in edits[entity.id] = edit }
        var meshRequests: [Entity.ID: MeshTerrain3DEdit] = [:]
        meshEdits.forEach { entity, edit in meshRequests[entity.id] = edit }
        var pending: [TerrainSourceRow] = []
        sources.forEach { entity, source in
            live.insert(entity.id)
            guard !acknowledging.contains(entity.id) else {
                return
            }
            let state = entity.components[TerrainSourceState.self]
            let matrix = Self.worldMatrix(entity)
            let transactionPins = saveQueue.pinnedRegions(owner: entity.id, storage: state?.storage)
            let pinsChanged = (state?.residency?.transactionPins ?? []) != transactionPins
            let edited = state.map { value in value.storage.map { $0.revision != value.revision } ?? false } ?? false
            let attemptedMatrix = state?.attemptedMatrix ?? state?.matrix
            let usesPlacementCollision = source.generatesCollision && source.instanceCollision.maximumCount > 0
                && (state?.instanceCells.values.contains { !$0.prepared.collisionPlacements.isEmpty } ?? false)
            let usesCameras = state?.meshAsset == nil && (source.maximumLOD > 0 || source.streamingRadius != nil || usesPlacementCollision)
            let focus = TerrainSourceFocus(
                cameras: cameraPositions ?? [],
                allCameraRegions: cameraPositions == nil,
                physics: source.generatesCollision ? .project(physicsBounds, inverse: matrix.inverse) : .init()
            )
            let cameraChanged = usesCameras && (state?.focus?.cameras != focus.cameras || state?.focus?.allCameraRegions != focus.allCameraRegions)
            let focusChanged = !source.source.isEmpty && (cameraChanged || state?.focus?.physics != focus.physics)
            let save = saveRequests[entity.id]
            if Self.routeSave(
                entity: entity,
                source: source,
                state: state,
                request: save,
                changed: state?.attempted != source || attemptedMatrix != matrix || edited || focusChanged || edits[entity.id] != nil,
                geometryBusy: jobs[entity.id] != nil,
                queue: saveQueue,
                commands: commands.queue
            ) {
                stopWaiting(entity.id)
                return
            }
            let preparing = entity.components[Terrain3DSourceStatus.self]?.isPreparing == true
            if jobs[entity.id] == nil, let editStatus = entity.components[Terrain3DHeightEditStatus.self],
                editStatus.phase == .pending, editStatus.id != edits[entity.id]?.id {
                let id = entity.id
                commands.queue.push { world in
                    guard let owner = world.getEntityByID(id), owner.components[Terrain3DHeightEditStatus.self]?.id == editStatus.id,
                        owner.components[Terrain3DHeightEditStatus.self]?.phase == .pending,
                        owner.components[Terrain3DHeightEdit.self]?.id != editStatus.id
                    else {
                        return
                    }
                    owner.components[Terrain3DHeightEditStatus.self] = .init(id: editStatus.id, phase: .cancelled, error: nil, delta: nil)
                }
            }
            let changed = state?.attempted != source || attemptedMatrix != matrix || edited || focusChanged || pinsChanged || preparing || edits[entity.id] != nil || meshRequests[entity.id] != nil
            if changed || jobs[entity.id] != nil {
                pending.append(
                    .init(
                        id: entity.id,
                        source: source,
                        matrix: matrix,
                        state: state,
                        focus: focus,
                        changed: changed,
                        edit: edits[entity.id],
                        meshEdit: meshRequests[entity.id]
                    )
                )
            }
        }
        for (id, edit) in edits where !live.contains(id) {
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == nil else {
                    return
                }
                Self.finishHeightEdit(edit, phase: .failed, error: TerrainHeightEditError.sourceUnavailable.localizedDescription, owner: owner)
            }
        }
        saves.forEach { entity, request in
            guard !live.contains(entity.id) else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == nil else {
                    return
                }
                Self.finishSave(request, phase: .failed, error: TerrainSourceSaveError.sourceUnavailable.localizedDescription, owner: owner)
            }
        }
        let removed = ownedSources.subtracting(live)
        ownedSources = live
        waiting.removeAll { !live.contains($0) }
        waitingSet.formIntersection(live)
        for id in jobs.keys.filter({ !live.contains($0) }) { jobs.removeValue(forKey: id)?.cancel() }
        if !removed.isEmpty {
            commands.queue.push { world in
                for id in removed { Self.setPhysicsPending(false, owner: id, world: world) }
            }
        }
        instances.forEach { entity, state in
            guard entity.components[Terrain3DSource.self] == nil else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == nil else {
                    return
                }
                for tile in state.tiles.values { Self.remove(tile, world: world) }
                for collider in state.instanceColliders.values { world.removeEntity(collider.entity, recursively: true) }
                owner.components.remove(TerrainSourceState.self)
                for cell in state.instanceCells.values {
                    for id in cell.entities { world.removeEntity(id, recursively: true) }
                }
                owner.components.remove(Terrain3DSourceSurface.self)
                owner.components.remove(MeshTerrain3DSourceSurface.self)
                owner.components.remove(MeshTerrain3DSourceResources.self)
                owner.components.remove(MeshTerrain3DEdit.self)
                owner.components.remove(MeshTerrain3DEditStatus.self)
                owner.components.remove(Terrain3DSourceStatus.self)
                owner.components.remove(Terrain3DHeightEdit.self)
                owner.components.remove(Terrain3DHeightEditStatus.self)
                owner.components.remove(Terrain3DSave.self)
                owner.components.remove(Terrain3DSaveStatus.self)
                Self.setPhysicsPending(false, owner: id, world: world)
            }
        }
        for row in pending {
            let id = row.id
            let source = row.source
            let matrix = row.matrix
            let state = row.state
            let focus = row.focus
            var edit = row.edit
            var meshEdit = row.meshEdit
            do {
                try Self.validate(source, matrix: matrix)
                var needsWork = row.changed
                if let job = jobs[id] {
                    if !job.request.accepts(source, editID: edit?.id, meshEditID: meshEdit?.id) || job.request.isStale {
                        job.cancel()
                        jobs.removeValue(forKey: id)
                        if let previousEdit = job.request.edit {
                            let stale = job.request.isStale && previousEdit.id == edit?.id
                            commands.queue.push { world in
                                guard let owner = world.getEntityByID(id) else {
                                    return
                                }
                                Self.finishHeightEdit(
                                    previousEdit,
                                    phase: stale ? .failed : .cancelled,
                                    error: stale ? TerrainHeightEditError.staleRevision.localizedDescription : nil,
                                    owner: owner
                                )
                            }
                            if previousEdit.id == edit?.id { edit = nil }
                        }
                        if let previous = job.request.meshEdit {
                            commands.queue.push { world in
                                if let owner = world.getEntityByID(id) { Self.cancelMeshPreview(previous, source: source, owner: owner) }
                            }
                            if meshEdit?.id == previous.id { meshEdit = nil }
                        }
                        needsWork = true
                    } else {
                        commands.queue.push { world in
                            guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source else {
                                return
                            }
                            Self.advance(job, source: source, owner: owner, world: world)
                        }
                        continue
                    }
                }
                if let superseded = meshEdit, superseded.ticket?.isSuperseded == true {
                    commands.queue.push { world in
                        if let owner = world.getEntityByID(id) { Self.cancelMeshPreview(superseded, source: source, owner: owner) }
                    }
                    meshEdit = nil
                }
                if let current = edit, let failure = Self.heightEditFailure(current, state: state, source: source) {
                    commands.queue.push { world in
                        guard let owner = world.getEntityByID(id) else {
                            return
                        }
                        Self.finishHeightEdit(current, phase: .failed, error: failure.localizedDescription, owner: owner)
                    }
                    edit = nil
                }
                guard needsWork else { stopWaiting(id); continue }
                if source.source.isEmpty {
                    stopWaiting(id)
                    commands.queue.push { world in
                        guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source else {
                            return
                        }
                        do {
                            try Self.apply(
                                nil,
                                source: source,
                                key: nil,
                                sourceError: nil,
                                failedLoad: nil,
                                focus: focus,
                                matrix: matrix,
                                owner: owner,
                                world: world
                            )
                        } catch { Self.recordFailure(error.localizedDescription, source: source, focus: focus, matrix: matrix, owner: owner, world: world) }
                    }
                    continue
                }
                if var presentation = state?.attempted, let state {
                    presentation.color = source.color
                    if edit == nil, !waitingSet.contains(id), state.attempted.color != source.color, presentation == source,
                        !preparingState(state, matrix: matrix, focus: focus), state.storage?.revision == state.revision {
                        commands.queue.push { world in
                            guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source,
                                var current = owner.components[TerrainSourceState.self]
                            else {
                                return
                            }
                            Self.updateMaterialColor(source.color, state: current, world: world)
                            current.attempted = source
                            owner.components[TerrainSourceState.self] = current
                        }
                        continue
                    }
                }
                let failedLoad = state?.failedLoad.flatMap { $0.key == TerrainSourceKey(source) ? $0 : nil }
                if let failedLoad, state?.storage == nil {
                    stopWaiting(id)
                    commands.queue.push { world in
                        guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source,
                            Self.worldMatrix(owner) == matrix
                        else {
                            return
                        }
                        Self.recordFailure(
                            failedLoad.message,
                            failedLoad: failedLoad,
                            source: source,
                            focus: focus,
                            matrix: matrix,
                            owner: owner,
                            world: world
                        )
                    }
                    continue
                }
                // Completed CPU results still occupy a slot until their GPU publication finishes.
                if waitingSet.insert(id).inserted { waiting.append(id) }
                if jobs.count < 2, waiting.first == id {
                    waiting.removeFirst()
                    waitingSet.remove(id)
                    jobs[id] = TerrainSourceJob(
                        request: .init(
                            source: source,
                            matrix: matrix,
                            focus: focus,
                            state: state,
                            edit: edit,
                            meshEdit: meshEdit,
                            transactionPins: saveQueue.pinnedRegions(owner: id, storage: state?.storage)
                        )
                    )
                }
                let queuedEdit = edit
                commands.queue.push { [meshEdit] world in
                    guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source else {
                        return
                    }
                    if let meshEdit, owner.components[MeshTerrain3DEdit.self]?.id == meshEdit.id {
                        owner.components[MeshTerrain3DEditStatus.self] = .init(id: meshEdit.id, phase: .pending, error: nil)
                    }
                    if let queuedEdit, owner.components[Terrain3DHeightEdit.self]?.id == queuedEdit.id {
                        owner.components[Terrain3DHeightEditStatus.self] = .init(id: queuedEdit.id, phase: .pending, error: nil, delta: nil)
                    }
                    owner.components[Terrain3DSourceStatus.self] = .init(
                        isReady: false, tileCount: state?.tiles.count ?? 0, isPreparing: true, instanceColliderCount: state?.instanceColliders.count ?? 0
                    )
                }
            } catch {
                jobs.removeValue(forKey: id)?.cancel()
                stopWaiting(id)
                let message = error.localizedDescription
                let failedEdit = edit
                commands.queue.push { world in
                    guard let owner = world.getEntityByID(id), owner.components[Terrain3DSource.self] == source,
                        Self.worldMatrix(owner) == matrix
                    else {
                        return
                    }
                    if let failedEdit { Self.finishHeightEdit(failedEdit, phase: .failed, error: message, owner: owner) }
                    Self.recordFailure(
                        message,
                        source: source,
                        focus: focus,
                        matrix: matrix,
                        owner: owner,
                        world: world
                    )
                }
            }
        }
    }

    private func stopWaiting(_ id: Entity.ID) {
        guard waitingSet.remove(id) != nil else {
            return
        }
        waiting.removeAll { $0 == id }
    }

    private func preparingState(_ state: TerrainSourceState, matrix: Transform3D, focus: TerrainSourceFocus) -> Bool {
        state.matrix != matrix || state.attemptedMatrix.map { $0 != matrix } == true || state.focus != focus
    }

    private func activeCameraPositions() -> [Vector3]? {
        var positions: [Vector3] = []
        var overflow = false
        cameras.forEach { entity, camera in
            guard entity.isActive, camera.isActive else {
                return
            }
            let position = Self.worldMatrix(entity).origin
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite else {
                return
            }
            if positions.count < TerrainCameraLOD.maximumCameras { positions.append(position) } else { overflow = true }
        }
        // Extra views conservatively retain full detail rather than overlooking an active camera.
        if overflow {
            return nil
        }
        return positions.sorted { left, right in
            if left.x != right.x {
                return left.x < right.x
            }
            if left.y != right.y {
                return left.y < right.y
            }
            return left.z < right.z
        }
    }
}

extension Terrain3DSourceSystem {
    static func validate(_ source: Terrain3DSource, matrix: Transform3D) throws {
        guard source.maximumResidentHeightBytes >= 0, (1...16_384).contains(source.maximumResidentRegions), source.maximumMeshBytes >= 0,
            (0...6).contains(source.maximumLOD), source.lodDistance.isFinite, source.lodDistance > 0,
            source.streamingRadius.map({ $0.isFinite && $0 > 0 }) ?? true,
            source.physicsPadding.isFinite, source.physicsPadding >= 0,
            (1...64).contains(source.maximumTileUpdatesPerFrame),
            source.color.x.isFinite, source.color.y.isFinite, source.color.z.isFinite, source.color.w.isFinite
        else {
            throw TerrainSourceError.invalidConfiguration
        }
        try source.instanceCollision.validate()
        try validateMatrix(matrix)
    }

    private static func validateMatrix(_ matrix: Transform3D) throws {
        let columns = [matrix.x, matrix.y, matrix.z, matrix.w]
        guard matrix.determinant.isFinite, matrix.determinant != 0,
            columns.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite })
        else {
            throw TerrainSourceError.invalidTransform
        }
    }

    @concurrent
    static func prepare(
        _ input: TerrainResidencyInput,
        revisions: [TerrainTileCoordinate: UInt64],
        previousSelections: [TerrainTileCoordinate: TerrainLODSelection],
        cameraPositions: [Vector3],
        matrix: Transform3D,
        source: Terrain3DSource,
        retainingLOD: Bool = false,
        previousInstanceCells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell] = [:],
        previousCanonical: [TerrainTileCoordinate: MeshDescriptor] = [:],
        previousQueries: [TerrainTileCoordinate: TerrainPreparedQuery] = [:],
        physicsInterests: TerrainPhysicsInterests = .init(),
        previousInstanceColliders: [UInt64: TerrainPreparedInstanceCollider] = [:],
        allCameraRegions: Bool = false
    ) async throws -> TerrainSourceBuild {
        let storage = input.storage
        let revision = storage.revision
        let coordinates = storage.tileCoordinates
        let materialResolver = try input.residency?.cache.manifest.materials.map(TerrainMaterialResolver.init)
        if materialResolver != nil { _ = try TerrainSourceMaterialUpload.inverseSpacing(storage.spacing) }
        // Conservative full-tile vertex/index bound, checked before allocating any snapshot arrays.
        // Positions, normals, UVs and renderer padding fit in 64 bytes per vertex.
        // Material fields reserve canonical rows plus their derived render staging separately.
        let materialBytesPerVertex = materialResolver == nil ? 0 : 64
        let bytesPerTile = 65 * 65 * (64 + materialBytesPerVertex) + 64 * 64 * 6 * MemoryLayout<UInt32>.stride
        let surface = storage.surfaceSnapshot()
        var tileBytes = 0
        var surfaceCoverageRowVisitCount = 0
        for coordinate in coordinates {
            try Task.checkCancellation()
            let cells = storage.tileCellCounts(at: coordinate)
            let coverage = materialResolver != nil
                ? surface.surfaceOverrideCoverage(in: coordinate, cellCountX: cells?.x ?? 64, cellCountZ: cells?.z ?? 64)
                : (painted: false, rowVisits: 0)
            surfaceCoverageRowVisitCount += coverage.rowVisits
            // Optional tint/mask rows, GPU atlas, retained generation and staging fit in another64 bytes/sample.
            let charge = bytesPerTile + (coverage.painted ? 65 * 65 * 64 : 0)
            guard charge <= source.maximumMeshBytes - tileBytes else { throw TerrainSourceError.meshBudgetExceeded }
            tileBytes += charge
        }
        var residency = input.residency
        let volumes = try await TerrainSourceVolumes.prepare(storage: storage, residency: residency, maximumBytes: source.maximumMeshBytes - tileBytes)
        residency?.volume = volumes.state
        tileBytes += volumes.chargedBytes
        var selections: [TerrainTileCoordinate: TerrainLODSelection]
        if retainingLOD {
            var proposed: [TerrainTileCoordinate: Int] = [:]
            var partial: Set<TerrainTileCoordinate> = []
            for coordinate in coordinates {
                proposed[coordinate] = previousSelections[coordinate]?.level ?? 0
                if let cells = storage.tileCellCounts(at: coordinate), cells.x != 64 || cells.z != 64 { partial.insert(coordinate) }
            }
            selections = try TerrainLODBalancer.select(proposed: proposed, partialTiles: partial)
        } else {
            selections = try TerrainCameraLOD.select(
                storage: storage,
                coordinates: coordinates,
                cameraPositions: cameraPositions,
                inverse: matrix.inverse,
                maximumLevel: source.maximumLOD,
                distance: source.lodDistance,
                previous: previousSelections
            )
        }
        if !volumes.tiles.isEmpty {
            selections = try TerrainLODBalancer.select(proposed: selections.mapValues(\.level), fullDetailTiles: Set(volumes.tiles.keys))
        }
        var changed: [TerrainTileCoordinate: TerrainSourcePreparedTile] = [:]
        var canonicalChanged: Set<TerrainTileCoordinate> = []
        var materialSampleEvaluationCount = 0
        var queryPreparation = try TerrainSourceQueryPreparation(settings: source.queries)
        for coordinate in coordinates {
            try Task.checkCancellation()
            let dataChanged = revisions[coordinate] != storage.tileRevision(at: coordinate) || volumes.changed.contains(coordinate)
            guard let selection = selections[coordinate] else { throw TerrainSourceError.changedDuringBuild }
            if dataChanged { canonicalChanged.insert(coordinate) }
            let needsQuery = queryPreparation.isEnabled && previousQueries[coordinate] == nil
            if !dataChanged, previousSelections[coordinate] == selection, !needsQuery {
                try queryPreparation.retain(previousQueries[coordinate])
                continue
            }
            if let snapshot = storage.snapshot(of: coordinate) {
                let canonical: MeshDescriptor
                if let volume = volumes.tiles[coordinate] {
                    if let materialResolver {
                        let field = try TerrainSourceMaterials.prepareVolume(volume.descriptor, storage: storage, resolver: materialResolver)
                        canonical = field.descriptor
                        materialSampleEvaluationCount += field.evaluations
                    } else { canonical = volume.descriptor }
                } else if !dataChanged, let previous = previousCanonical[coordinate],
                    materialResolver == nil || (previous[TerrainSourceMaterials.layerIDs] != nil && previous[TerrainSourceMaterials.weights] != nil) {
                    canonical = previous
                } else if let materialResolver {
                    let field = try TerrainSourceMaterials.prepare(snapshot, storage: storage, resolver: materialResolver)
                    canonical = field.descriptor
                    materialSampleEvaluationCount += field.evaluations
                } else {
                    canonical = snapshot.meshDescriptor()
                }
                // Compare only changed worker snapshots. Paint changes canonical material rows,
                // while direct height writes and LOD/stitch changes must still rebuild geometry.
                let previous = previousCanonical[coordinate]
                let sameCollision = previous.map { canonical.positions.elements == $0.positions.elements && canonical.indicies == $0.indicies } ?? false
                let sameMesh = sameCollision && previousSelections[coordinate] == selection
                    && canonical.normals?.elements == previous?.normals?.elements
                    && canonical.textureCoordinates?.elements == previous?.textureCoordinates?.elements
                let display: MeshDescriptor
                if volumes.tiles[coordinate] != nil {
                    display = TerrainSourceMaterials.displayGeometry(canonical)
                } else {
                    display = try snapshot.meshLOD(level: selection.level, finerEdges: selection.finerEdges).descriptor
                }
                changed[coordinate] = .init(
                    canonical: canonical,
                    display: display,
                    revision: snapshot.revision,
                    reusesMesh: sameMesh,
                    reusesCollision: sameCollision,
                    query: try queryPreparation.prepare(canonical, previous: previousQueries[coordinate], sameGeometry: sameCollision)
                )
            }
        }
        var materialBytes = 0
        if let palette = residency?.cache.manifest.materials, let cache = residency?.cache {
            let available = source.maximumMeshBytes - tileBytes
            let maps: TerrainPreparedMaterialMaps
            if let existing = residency?.materialMaps { maps = existing } else {
                maps = try await TerrainPreparedMaterialMaps.prepare(palette: palette, cache: cache, maximumBytes: available)
            }
            guard maps.chargedBytes <= available else { throw TerrainSourceError.meshBudgetExceeded }
            residency?.materialMaps = maps
            materialBytes = maps.chargedBytes
        }
        let instances = try await TerrainSourceInstances.prepare(
            storage: storage,
            residency: residency,
            previous: previousInstanceCells,
            maximumBytes: source.maximumMeshBytes - tileBytes - materialBytes
        )
        let instanceColliders = try TerrainSourceInstanceCollisions.prepare(
            cells: instances.cells,
            prototypes: instances.residency?.prototypes ?? [:],
            cameras: cameraPositions,
            physics: .init(rectangles: physicsInterests.rectangles, requiresAllRegions: physicsInterests.requiresAllRegions || allCameraRegions),
            matrix: matrix,
            source: source,
            previous: previousInstanceColliders
        )
        guard storage.revision == revision else { throw TerrainSourceError.changedDuringBuild }
        return .init(
            storage: storage,
            revision: revision,
            coordinates: coordinates,
            changed: changed,
            canonicalChanged: canonicalChanged,
            selections: selections,
            target: input.target,
            expectedTargetRevision: input.expectedRevision,
            residency: instances.residency,
            instanceCells: instances.cells,
            instanceColliders: instanceColliders,
            groupedInstanceRecordCount: instances.groupedRecordCount,
            materialSampleEvaluationCount: materialSampleEvaluationCount,
            surfaceCoverageRowVisitCount: surfaceCoverageRowVisitCount
        )
    }

    static func apply(
        _ build: TerrainSourceBuild?,
        source: Terrain3DSource,
        key: TerrainSourceKey?,
        sourceError: String?,
        failedLoad: TerrainSourceFailedLoad?,
        focus: TerrainSourceFocus,
        matrix: Transform3D,
        owner: Entity,
        world: World,
        materialArrays: TerrainMaterialTextureArrays? = nil,
        materials: [TerrainTileCoordinate: PBRMaterial] = [:],
        meshes: [TerrainTileCoordinate: Mesh] = [:],
        shapes: [TerrainTileCoordinate: Shape3DResource] = [:],
        instanceShapes: [UInt64: Shape3DResource] = [:]
    ) throws {
        let previous = owner.components[TerrainSourceState.self]
        guard let build else {
            for tile in previous?.tiles.values ?? [:].values { remove(tile, world: world) }
            for collider in previous?.instanceColliders.values ?? [:].values { world.removeEntity(collider.entity, recursively: true) }
            for cell in previous?.instanceCells.values ?? [:].values {
                for id in cell.entities { world.removeEntity(id, recursively: true) }
            }
            owner.components.remove(Terrain3DSourceSurface.self)
            owner.components.remove(MeshTerrain3DSourceSurface.self)
            owner.components.remove(MeshTerrain3DSourceResources.self)
            owner.components[TerrainSourceState.self] = .init(
                attempted: source,
                key: nil,
                storage: nil,
                revision: 0,
                matrix: matrix,
                focus: focus,
                material: previous?.material ?? PBRMaterial(),
                tiles: [:]
            )
            owner.components[Terrain3DSourceStatus.self] = .init(isReady: true, tileCount: 0, error: nil)
            setPhysicsPending(false, owner: owner.id, world: world)
            return
        }
        let material = previous?.material ?? PBRMaterial()
        let collision = source.generatesCollision && world.getResource(Physics3DWorldHolder.self) != nil
        let selectedInstanceColliders = collision ? build.instanceColliders : [:]
        try validateInstanceColliders(selectedInstanceColliders, previous: previous?.instanceColliders ?? [:], shapes: instanceShapes, world: world)
        if let target = build.target, let expected = build.expectedTargetRevision {
            try target.commitResidency(build.storage, expectedRevision: expected)
        }
        let publishedStorage = build.target ?? build.storage
        var tiles = previous?.tiles ?? [:]
        let desired = Set(build.coordinates)
        for coordinate in tiles.keys.filter({ !desired.contains($0) }) {
            if let tile = tiles.removeValue(forKey: coordinate) { remove(tile, world: world) }
        }
        if material.baseColorFactor != source.color { material.baseColorFactor = source.color }
        if material.roughnessFactor != 0.95 { material.roughnessFactor = 0.95 }
        for coordinate in build.coordinates {
            let old = tiles[coordinate]
            let snapshot = build.changed[coordinate]
            guard let descriptor = snapshot?.canonical ?? old?.descriptor,
                let display = snapshot?.display ?? old?.displayDescriptor, let selection = build.selections[coordinate]
            else { continue }
            let entity = old.flatMap { world.getEntityByID($0.entity) } ?? world.spawn("Terrain Tile \(coordinate.x),\(coordinate.z)")
            let previousMaterial = entity.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial
            let tileMaterial = build.materialPalette == nil ? material : materials[coordinate] ?? previousMaterial ?? material
            if tileMaterial.baseColorFactor != source.color { tileMaterial.baseColorFactor = source.color }
            if let mesh = meshes[coordinate] {
                let drawMaterials: [Material] = [tileMaterial] + (snapshot?.sourceDraws?.makeMaterials() ?? [])
                entity.components[Mesh3DComponent.self] = .init(mesh: mesh, materials: drawMaterials)
            } else if materials[coordinate] != nil, var component = entity.components[Mesh3DComponent.self] {
                component.materials = [tileMaterial] + Array(component.materials.dropFirst())
                entity.components[Mesh3DComponent.self] = component
            }
            if old == nil || entity.components[TerrainTile3DComponent.self] == nil {
                entity.components[TransientEntity.self] = .init()
                entity.components[TerrainGenerated3D.self] = .init(owner: owner.id, sourceBacked: true)
                entity.components[Transform.self] = Transform()
                entity.components[TerrainTile3DComponent.self] = .init(coordinate: coordinate)
                owner.addChild(entity)
            }
            var collider = old?.collider
            if !collision || shapes[coordinate] != nil {
                if let collider { world.removeEntity(collider, recursively: true) }
                collider = nil
                if collision, let shape = shapes[coordinate] {
                    collider = makeCollider(shape, owner: owner, world: world)
                }
            }
            tiles[coordinate] = .init(
                entity: entity.id,
                collider: collider,
                descriptor: descriptor,
                displayDescriptor: display,
                revision: snapshot?.revision ?? old?.revision ?? 0,
                selection: selection,
                query: source.queries == nil ? nil : snapshot?.query ?? old?.query
            )
        }
        let instanceColliders = applyInstanceColliders(
            selectedInstanceColliders, previous: previous?.instanceColliders ?? [:], shapes: instanceShapes, owner: owner, world: world
        )
        owner.components[Terrain3DSourceSurface.self] = .init(
            storage: publishedStorage,
            queries: source.queries == nil ? nil : TerrainSurfaceQueries(revision: build.revision, queries: tiles.compactMapValues(\.query)),
            manifest: build.residency?.cache.manifest
        )
        if let asset = build.meshAsset, let manifest = build.meshManifest {
            owner.components.remove(Terrain3DSourceSurface.self)
            let sections = Dictionary(uniqueKeysWithValues: (asset.compiled?.patches ?? []).enumerated().map { ($0.element.id, TerrainTileCoordinate(x: $0.offset, z: 0)) })
            owner.components[MeshTerrain3DSourceSurface.self] = .init(asset: asset,
                queries: source.queries == nil ? nil : TerrainSurfaceQueries(revision: build.meshQueryRevision ?? build.revision, queries: tiles.compactMapValues(\.query)), sections: sections)
            owner.components[MeshTerrain3DSourceResources.self] = .init(manifest: manifest)
        } else {
            owner.components.remove(MeshTerrain3DSourceSurface.self)
            owner.components.remove(MeshTerrain3DSourceResources.self)
        }
        owner.components[Terrain3DSourceStatus.self] = .init(
            isReady: sourceError == nil, tileCount: tiles.count, error: sourceError, warnings: build.preparedMaterialMaps?.warnings ?? [], instanceColliderCount: instanceColliders.count
        )
        owner.components[TerrainSourceState.self] = .init(
            attempted: source,
            publishedSettings: sourceError == nil ? source : previous?.publishedSettings,
            key: key,
            storage: build.meshAsset == nil ? publishedStorage : nil,
            revision: build.revision,
            matrix: matrix,
            failedLoad: failedLoad,
            diagnostic: sourceError,
            focus: focus,
            residency: build.residency,
            materialArrays: materialArrays ?? previous?.materialArrays.flatMap { $0.sourceID == build.preparedMaterialMaps?.id ? $0 : nil },
            material: material,
            tiles: tiles,
            instanceCells: TerrainSourceInstances.apply(build.instanceCells, previous: previous?.instanceCells ?? [:], owner: owner, world: world),
            instanceColliders: instanceColliders,
            meshAsset: build.meshAsset,
            meshEvaluator: build.meshEvaluator,
            meshPrototypes: build.meshPrototypes,
            meshMaterials: build.meshMaterials,
            meshMaskedSources: previous?.meshMaskedSources ?? [],
            meshCollisionSources: previous?.meshCollisionSources ?? [],
            meshBindings: previous?.meshBindings ?? [:],
            groupedInstanceRecordCount: build.groupedInstanceRecordCount,
            materialSampleEvaluationCount: build.materialSampleEvaluationCount,
            surfaceCoverageRowVisitCount: build.surfaceCoverageRowVisitCount
        )
        setPhysicsPending(sourceError != nil && source.generatesCollision && !focus.physics.isEmpty, owner: owner.id, world: world)
    }

    static func recordFailure(
        _ message: String,
        failedLoad: TerrainSourceFailedLoad? = nil,
        source: Terrain3DSource,
        focus: TerrainSourceFocus,
        matrix: Transform3D,
        owner: Entity,
        world: World
    ) {
        var state =
            owner.components[TerrainSourceState.self]
            ?? .init(
                attempted: source,
                key: nil,
                storage: nil,
                revision: 0,
                matrix: matrix,
                material: PBRMaterial(),
                tiles: [:]
            )
        var diagnostic = message
        if state.storage != nil {
            do { try refreshResident(&state, source: source, matrix: matrix, world: world) } catch { diagnostic += "; resident surface update failed: \(error.localizedDescription)" }
        }
        state.attempted = source
        state.diagnostic = diagnostic
        state.attemptedMatrix = matrix
        if let failedLoad { state.failedLoad = failedLoad }
        state.focus = focus
        owner.components[TerrainSourceState.self] = state
        owner.components[Terrain3DSourceStatus.self] = .init(isReady: false, tileCount: state.tiles.count, error: diagnostic, instanceColliderCount: state.instanceColliders.count)
        setPhysicsPending(source.generatesCollision && !focus.physics.isEmpty, owner: owner.id, world: world)
    }

    static func setPhysicsPending(_ pending: Bool, owner: Entity.ID, world: World) {
        world.getResource(PhysicsSimulationGate3D.self)?.setPending(owner: owner, reason: "terrain", pending: pending)
    }

    private static func refreshResident(_ state: inout TerrainSourceState, source: Terrain3DSource, matrix: Transform3D, world: World) throws {
        try validateMatrix(matrix)
        let collision = source.generatesCollision && world.getResource(Physics3DWorldHolder.self) != nil
        // Recovery jobs prepare retained collision incrementally. Configuration/renderer failures
        // keep the old collision pose and its simulation hold instead of cooking an unbounded batch.
        if !collision {
            for collider in state.instanceColliders.values { world.removeEntity(collider.entity, recursively: true) }
            state.instanceColliders.removeAll()
            for coordinate in state.tiles.keys {
                guard var tile = state.tiles[coordinate] else { continue }
                if let collider = tile.collider { world.removeEntity(collider, recursively: true) }
                tile.collider = nil
                state.tiles[coordinate] = tile
            }
        }
        if source.color.x.isFinite, source.color.y.isFinite, source.color.z.isFinite, source.color.w.isFinite,
            state.material.baseColorFactor != source.color {
            updateMaterialColor(source.color, state: state, world: world)
        }
        if !collision || (state.tiles.isEmpty && state.instanceColliders.isEmpty) { state.matrix = matrix }
    }

    private static func updateMaterialColor(_ color: Vector4, state: TerrainSourceState, world: World) {
        state.material.baseColorFactor = color
        for tile in state.tiles.values {
            guard let material = world.getEntityByID(tile.entity)?.components[Mesh3DComponent.self]?.materials.first as? PBRMaterial,
                material.baseColorFactor != color
            else { continue }
            material.baseColorFactor = color
        }
    }

    static func makeCollider(_ shape: Shape3DResource, owner: Entity, world: World, name: String = "Terrain Collision") -> Entity.ID {
        let child = world.spawn(name)
        child.components[TransientEntity.self] = .init()
        child.components[TerrainGenerated3D.self] = .init(owner: owner.id, sourceBacked: true)
        child.components[Transform.self] = Transform()
        child.components[PhysicsBody3DComponent.self] = .init(shapes: [shape], mode: .static)
        owner.addChild(child)
        if let physics = world.getResource(Physics3DWorldHolder.self) {
            Physics3DSyncSystem.initializeImmediately(child, in: physics.world)
        }
        return child.id
    }

    private static func remove(_ tile: TerrainSourceTile, world: World) {
        world.removeEntity(tile.entity, recursively: true)
        if let collider = tile.collider { world.removeEntity(collider, recursively: true) }
    }

    static func worldMatrix(_ entity: Entity, overriding poses: [Entity.ID: Transform] = [:]) -> Transform3D {
        var matrix = (poses[entity.id] ?? entity.components[Transform.self])?.matrix ?? .identity
        var parentID = entity.components[RelationshipComponent.self]?.parent
        var visited: Set<Entity.ID> = [entity.id]
        while let id = parentID, visited.insert(id).inserted, let parent = entity.world?.getEntityByID(id) {
            matrix = ((poses[id] ?? parent.components[Transform.self])?.matrix ?? .identity) * matrix
            parentID = parent.components[RelationshipComponent.self]?.parent
        }
        return matrix
    }
}
