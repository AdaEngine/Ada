import AdaAssets
import AdaECS
@_spi(Internal) import AdaPhysics
@_spi(Internal) import AdaRender
import AdaTransform
import Foundation
import Math
import Synchronization

extension Terrain3DSourceSystem {
    static func makeShape(_ descriptor: MeshDescriptor, matrix: Transform3D, metrics: PhysicsCollisionPreparationMetrics?) throws -> Shape3DResource {
        var indices = descriptor.indicies
        if matrix.determinant < 0 {
            for index in stride(from: 0, to: indices.count, by: 3) { indices.swapAt(index + 1, index + 2) }
        }
        let shape = try Shape3DResource.generateTriangleMesh(vertices: descriptor.positions.elements.map { (matrix * Vector4($0, 1)).xyz }, indices: indices)
        try shape.prepareStaticCollision(metrics: metrics)
        return shape
    }

    static func advance(_ job: TerrainSourceJob, source: Terrain3DSource, owner: Entity, world: World) {
        let matrix = worldMatrix(owner)
        do {
            try validate(source, matrix: matrix)
            try job.box.value.withLock { state in
                guard !state.finished else {
                    return
                }
                if let edit = job.request.meshEdit, edit.ticket?.isSuperseded == true {
                    cancelMeshPreview(edit, source: source, owner: owner)
                    state.finished = true
                    return
                }
                guard job.request.accepts(source, editID: owner.components[Terrain3DHeightEdit.self]?.id, meshEditID: owner.components[MeshTerrain3DEdit.self]?.id), !job.request.isStale else {
                    state.finished = true
                    return
                }
                if state.publication == nil {
                    guard let outcome = state.outcome else {
                        return
                    }
                    state.outcome = nil
                    switch outcome {
                    case .stale: state.finished = true; return
                    case let .meshEditFailed(message):
                        if let edit = job.request.meshEdit { finishMeshEdit(edit, phase: .failed, error: message, owner: owner) }
                        restoreSourceStatus(owner, source: source)
                        state.finished = true
                        return
                    case let .editFailed(message):
                        if let edit = job.request.edit {
                            finishHeightEdit(edit, phase: .failed, error: message, owner: owner)
                            restoreSourceStatus(owner, source: source)
                        }
                        state.finished = true
                        return
                    case let .failed(message, failure):
                        recordFailure(message, failedLoad: failure, source: source, focus: job.request.focus, matrix: matrix, owner: owner, world: world)
                        state.finished = true
                        return
                    case let .prepared(product):
                        let collision = source.generatesCollision && world.getResource(Physics3DWorldHolder.self) != nil
                        state.publication = .init(
                            product: product,
                            matrix: matrix,
                            collision: collision,
                            coordinates: workCoordinates(product.build, owner: owner, world: world, matrix: matrix, collision: collision)
                        )
                    }
                }
                guard var publication = state.publication else {
                    return
                }
                state.publication = nil
                let build = publication.product.build
                guard build.storage.revision == build.revision,
                    build.target == nil || build.target?.revision == build.expectedTargetRevision
                else { state.finished = true; return }
                if publication.matrix != matrix {
                    publication.matrix = matrix
                    if publication.collision {
                        publication.shapes.removeAll(keepingCapacity: true)
                        publication.instanceShapes.removeAll(keepingCapacity: true)
                        publication.instanceCoordinates = nil
                        publication.instanceCursor = 0
                        publication.cursor = 0
                        publication.coordinates = workCoordinates(build, owner: owner, world: world, matrix: matrix, collision: true)
                    }
                }
                guard let engine = unsafe RenderEngine.shared else { throw AssetError.message("Terrain renderer is unavailable") }
                let previous = owner.components[TerrainSourceState.self]
                let end = min(publication.coordinates.count, publication.cursor + source.maximumTileUpdatesPerFrame)
                for index in publication.cursor..<end {
                    let coordinate = publication.coordinates[index]
                    let old = previous?.tiles[coordinate]
                    let prepared = build.changed[coordinate]
                    guard let canonical = prepared?.canonical ?? old?.descriptor,
                        let display = prepared?.display ?? old?.displayDescriptor
                    else { throw TerrainSourceError.changedDuringBuild }
                    let missingMesh = old.flatMap { world.getEntityByID($0.entity)?.components[Mesh3DComponent.self] } == nil
                    if let palette = build.materialPalette,
                        (build.canonicalChanged.contains(coordinate) || missingMesh), publication.materials[coordinate] == nil {
                        if publication.materialArrays == nil, let maps = build.preparedMaterialMaps {
                            if let previousArrays = previous?.materialArrays, previousArrays.sourceID == maps.id {
                                publication.materialArrays = previousArrays
                            } else {
                                if publication.materialUpload == nil { publication.materialUpload = try TerrainMaterialUpload(maps: maps) }
                                guard let arrays = try publication.materialUpload?.advance(metrics: world.getResource(TerrainMaterialUploadMetrics.self)) else {
                                    publication.cursor = index
                                    owner.components[Terrain3DSourceStatus.self] = .init(
                                        isReady: false,
                                        tileCount: previous?.tiles.count ?? 0,
                                        preparedTileCount: index,
                                        pendingTileCount: publication.coordinates.count,
                                        isPreparing: true,
                                        instanceColliderCount: previous?.instanceColliders.count ?? 0
                                    )
                                    state.publication = publication
                                    return
                                }
                                publication.materialArrays = arrays
                                publication.materialUpload = nil
                            }
                        }
                        guard let arrays = publication.materialArrays else { throw TerrainSourceError.changedDuringBuild }
                        publication.materials[coordinate] = try TerrainSourceMaterialUpload.make(
                            descriptor: canonical, coordinate: coordinate, storage: build.storage, palette: palette, maps: arrays, color: source.color,
                            device: engine.renderDevice, usesTriangleField: build.meshAsset != nil
                        )
                    }
                    if (prepared?.reusesMesh == false || missingMesh) && publication.meshes[coordinate] == nil {
                        publication.meshes[coordinate] = prepared?.sourceDraws?.mesh(using: engine.renderDevice)
                            ?? Mesh.generate(from: [display], renderDevice: engine.renderDevice)
                    }
                    if needsShape(coordinate, build: build, old: old, previous: previous, matrix: matrix, world: world), publication.collision,
                        publication.shapes[coordinate] == nil {
                        publication.shapes[coordinate] = try makeShape(
                            canonical,
                            matrix: matrix,
                            metrics: world.getResource(Physics3DWorldHolder.self)?.world.collisionPreparationMetrics
                        )
                    }
                }
                publication.cursor = end
                if end == publication.coordinates.count {
                    guard try advanceInstanceCollisions(&publication, source: source, previous: previous, world: world) else {
                        owner.components[Terrain3DSourceStatus.self] = .init(
                            isReady: false,
                            tileCount: previous?.tiles.count ?? 0,
                            preparedTileCount: end,
                            pendingTileCount: end,
                            isPreparing: true,
                            instanceColliderCount: previous?.instanceColliders.count ?? 0
                        )
                        state.publication = publication
                        return
                    }
                    let meshPublication = try job.request.meshEdit.map { try validateMeshEditPublication($0, owner: owner, world: world) } ?? .init(poses: [], bindings: [:])
                    // This is the linearization point with newly arriving pointer input.
                    if let edit = job.request.meshEdit, edit.ticket?.claim() == false {
                        cancelMeshPreview(edit, source: source, owner: owner)
                        state.finished = true
                        return
                    }
                    try apply(
                        build,
                        source: source,
                        key: publication.product.key,
                        sourceError: publication.product.diagnostic ?? publication.product.failure?.message,
                        failedLoad: publication.product.failure,
                        focus: job.request.focus,
                        matrix: matrix,
                        owner: owner,
                        world: world,
                        materialArrays: publication.materialArrays,
                        materials: publication.materials,
                        meshes: publication.meshes,
                        shapes: publication.shapes,
                        instanceShapes: publication.instanceShapes
                    )
                    if var current = owner.components[TerrainSourceState.self] {
                        current.attempted = job.request.source
                        current.attempted.color = source.color
                        current.attempted.maximumTileUpdatesPerFrame = source.maximumTileUpdatesPerFrame
                        current.attemptedMatrix = job.request.matrix == matrix ? nil : job.request.matrix
                        owner.components[TerrainSourceState.self] = current
                    }
                    if let edit = job.request.meshEdit {
                        publishMeshSourcePoses(edit, poses: meshPublication.poses, world: world)
                        publishMeshSourceDraws(edit, owner: owner, world: world)
                        if let selected = edit.collisionReplacements { MeshTerrainSourceCollisionOwnership.publish(selected, owner: owner, world: world) }
                        MeshTerrainBindingLifecycle.publish(edit.bindingChanges, owner: owner, world: world)
                        MeshTerrainBindingUpdates.publish(edit, prepared: meshPublication.bindings, owner: owner, world: world)
                        publishMeshResourceAdoption(edit, owner: owner)
                        finishMeshEdit(edit, phase: .applied, owner: owner)
                    }
                    if let edit = job.request.edit, let delta = publication.product.heightDelta {
                        finishHeightEdit(edit, phase: .applied, delta: delta, owner: owner)
                    }
                    state.finished = true
                } else {
                    owner.components[Terrain3DSourceStatus.self] = .init(
                        isReady: false,
                        tileCount: previous?.tiles.count ?? 0,
                        preparedTileCount: end,
                        pendingTileCount: publication.coordinates.count,
                        isPreparing: true,
                        instanceColliderCount: previous?.instanceColliders.count ?? 0
                    )
                    state.publication = publication
                }
            }
        } catch TerrainHeightStorage.StorageError.staleRevision { job.box.value.withLock { $0.finished = true } } catch TerrainSourceError.changedDuringBuild {
            job.box.value.withLock { $0.finished = true }
            if let edit = job.request.meshEdit {
                finishMeshEdit(edit, phase: .failed, error: TerrainSourceError.changedDuringBuild.localizedDescription, owner: owner)
                restoreSourceStatus(owner, source: source)
            }
        } catch {
            job.box.value.withLock { $0.finished = true }
            if let edit = job.request.meshEdit {
                finishMeshEdit(edit, phase: .failed, error: error.localizedDescription, owner: owner)
                restoreSourceStatus(owner, source: source)
            } else if let edit = job.request.edit {
                finishHeightEdit(edit, phase: .failed, error: error.localizedDescription, owner: owner)
                restoreSourceStatus(owner, source: source)
            } else {
                recordFailure(error.localizedDescription, source: source, focus: job.request.focus, matrix: matrix, owner: owner, world: world)
            }
        }
    }

    private static func workCoordinates(
        _ build: TerrainSourceBuild,
        owner: Entity,
        world: World,
        matrix: Transform3D,
        collision: Bool
    ) -> [TerrainTileCoordinate] {
        let previous = owner.components[TerrainSourceState.self]
        return build.coordinates.filter { coordinate in
            let old = previous?.tiles[coordinate]
            let missingMesh = old.flatMap { world.getEntityByID($0.entity)?.components[Mesh3DComponent.self] } == nil
            return build.changed[coordinate] != nil || missingMesh
                || collision && needsShape(coordinate, build: build, old: old, previous: previous, matrix: matrix, world: world)
        }
    }

    private static func needsShape(
        _ coordinate: TerrainTileCoordinate,
        build: TerrainSourceBuild,
        old: TerrainSourceTile?,
        previous: TerrainSourceState?,
        matrix: Transform3D,
        world: World
    ) -> Bool {
        (build.canonicalChanged.contains(coordinate) && build.changed[coordinate]?.reusesCollision != true) || previous?.matrix != matrix
            || old?.collider.flatMap { world.getEntityByID($0)?.components[PhysicsBody3DComponent.self] } == nil
    }
}
