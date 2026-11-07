import AdaAssets
import AdaECS
import AdaGeometry
import AdaPhysics
@_spi(Internal) import AdaRender
import Foundation
import Math
import Synchronization

struct TerrainSourceKey: Equatable, Sendable {
    let path: String
    let generation: UInt64

    init(_ source: Terrain3DSource) {
        path = source.source
        generation = source.reloadGeneration
    }
}

struct TerrainSourceTile: Sendable {
    let entity: Entity.ID
    var collider: Entity.ID?
    let descriptor: MeshDescriptor
    let displayDescriptor: MeshDescriptor
    let revision: UInt64
    let selection: TerrainLODSelection
    var query: TerrainPreparedQuery?
}

struct TerrainSourceFailedLoad: Sendable {
    let key: TerrainSourceKey
    let message: String
}

struct TerrainSourceState: Component {
    var saveJob: TerrainSourceSaveJob?
    var attempted: Terrain3DSource
    var publishedSettings: Terrain3DSource?
    var key: TerrainSourceKey?
    var storage: TerrainHeightStorage?
    var revision: UInt64
    // Published collision pose and last attempted pose are separate when a transform is invalid.
    var matrix: Transform3D
    var attemptedMatrix: Transform3D?
    var failedLoad: TerrainSourceFailedLoad?
    var diagnostic: String?
    var focus: TerrainSourceFocus?
    var residency: TerrainSourceResidency?
    var materialArrays: TerrainMaterialTextureArrays?
    var material: PBRMaterial
    var tiles: [TerrainTileCoordinate: TerrainSourceTile]
    var instanceCells: [TerrainInstanceCellKey: TerrainSourceInstanceCell] = [:]
    var instanceColliders: [UInt64: TerrainSourceInstanceCollider] = [:]
    var meshAsset: MeshTerrainDocumentAsset?
    var meshEvaluator: MeshTerrainEvaluator?
    var meshPrototypes: [UInt16: MeshTerrainPreparedPrototype] = [:]
    var meshMaterials: MeshTerrainPreparedMaterials?
    var meshMaskedSources: Set<Entity.ID> = []
    var meshCollisionSources: Set<Entity.ID> = []
    var meshBindings: [UUID: MeshTerrainBindingOwnership] = [:]
    var groupedInstanceRecordCount = 0
    var materialSampleEvaluationCount = 0
    var surfaceCoverageRowVisitCount = 0
}

struct TerrainSourceBuild: Sendable {
    let storage: TerrainHeightStorage
    let revision: UInt64
    let coordinates: [TerrainTileCoordinate]
    let changed: [TerrainTileCoordinate: TerrainSourcePreparedTile]
    let canonicalChanged: Set<TerrainTileCoordinate>
    let selections: [TerrainTileCoordinate: TerrainLODSelection]
    let target: TerrainHeightStorage?
    let expectedTargetRevision: UInt64?
    let residency: TerrainSourceResidency?
    var instanceCells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell] = [:]
    var instanceColliders: [UInt64: TerrainPreparedInstanceCollider] = [:]
    var meshAsset: MeshTerrainDocumentAsset?
    var meshManifest: TerrainManifestAsset?
    var meshEvaluator: MeshTerrainEvaluator?
    var meshPrototypes: [UInt16: MeshTerrainPreparedPrototype] = [:]
    var meshMaterials: MeshTerrainPreparedMaterials?
    var meshQueryRevision: UInt64?
    var groupedInstanceRecordCount = 0
    var materialSampleEvaluationCount = 0
    var surfaceCoverageRowVisitCount = 0

    var materialPalette: TerrainMaterialPalette? { meshMaterials?.palette ?? residency?.cache.manifest.materials }
    var preparedMaterialMaps: TerrainPreparedMaterialMaps? { meshMaterials?.maps ?? residency?.materialMaps }
}

struct TerrainSourcePreparedTile: Sendable {
    let canonical: MeshDescriptor
    let display: MeshDescriptor
    let revision: UInt64
    let reusesMesh: Bool
    let reusesCollision: Bool
    var query: TerrainPreparedQuery?
    var sourceDraws: MeshTerrainPreparedSourceDraws?
}

enum TerrainSourceError: LocalizedError {
    case invalidConfiguration, meshBudgetExceeded, changedDuringBuild, invalidTransform
    case resourceLoadingFailed(String)
    case instanceCollisionBudgetExceeded
    case unsupportedVolumeMaterials

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: "Invalid terrain source limits, LOD settings or color"
        case .meshBudgetExceeded: "Terrain mesh budget exceeded"
        case .changedDuringBuild: "Terrain changed while geometry was being prepared"
        case .invalidTransform: "Terrain requires a finite, nonsingular world transform"
        case .instanceCollisionBudgetExceeded: "Terrain placement collision exceeds its geometry or candidate-work budget"
        case .unsupportedVolumeMaterials: "Volume material fields are not connected yet; the last valid terrain remains published"
        case let .resourceLoadingFailed(message): message
        }
    }
}

struct TerrainSourceRow {
    let id: Entity.ID
    let source: Terrain3DSource
    let matrix: Transform3D
    let state: TerrainSourceState?
    let focus: TerrainSourceFocus
    let changed: Bool
    let edit: Terrain3DHeightEdit?
    var meshEdit: MeshTerrain3DEdit?
}

/// Values captured before leaving ECS iteration; workers never retain an Entity or World.
struct TerrainSourceRequest: Sendable {
    let source: Terrain3DSource
    let matrix: Transform3D
    let focus: TerrainSourceFocus
    let edit: Terrain3DHeightEdit?
    var meshEdit: MeshTerrain3DEdit?
    let meshAsset: MeshTerrainDocumentAsset?
    let meshEvaluator: MeshTerrainEvaluator?
    let meshPrototypes: [UInt16: MeshTerrainPreparedPrototype]
    let meshMaterials: MeshTerrainPreparedMaterials?
    let residentDiagnostic: String?
    let loadedKey: TerrainSourceKey?
    let storage: TerrainHeightStorage?
    let storageRevision: UInt64?
    let residentSettings: Terrain3DSource?
    let transactionPins: Set<TerrainRegionCoordinate>
    let residency: TerrainSourceResidency?
    let failedLoad: TerrainSourceFailedLoad?
    let revisions: [TerrainTileCoordinate: UInt64]
    let canonicalDescriptors: [TerrainTileCoordinate: MeshDescriptor]
    let displayDescriptors: [TerrainTileCoordinate: MeshDescriptor]
    let queryIndices: [TerrainTileCoordinate: TerrainPreparedQuery]
    let instanceCells: [TerrainInstanceCellKey: TerrainPreparedInstanceCell]
    let instanceColliders: [UInt64: TerrainPreparedInstanceCollider]
    let selections: [TerrainTileCoordinate: TerrainLODSelection]

    init(
        source: Terrain3DSource,
        matrix: Transform3D,
        focus: TerrainSourceFocus,
        state: TerrainSourceState?,
        edit: Terrain3DHeightEdit? = nil,
        meshEdit: MeshTerrain3DEdit? = nil,
        transactionPins: Set<TerrainRegionCoordinate> = []
    ) {
        self.source = source
        self.matrix = matrix
        self.focus = focus
        self.edit = edit
        self.transactionPins = transactionPins
        self.meshEdit = meshEdit
        meshAsset = state?.meshAsset; meshEvaluator = state?.meshEvaluator
        meshPrototypes = state?.meshPrototypes ?? [:]
        meshMaterials = state?.meshMaterials
        residentDiagnostic = state?.diagnostic
        loadedKey = state?.key
        storage = state?.storage
        storageRevision = state?.storage?.revision
        residentSettings = state?.publishedSettings ?? state?.attempted
        residency = state?.residency
        failedLoad = state?.failedLoad
        revisions = state?.tiles.mapValues(\.revision) ?? [:]
        canonicalDescriptors = state?.tiles.mapValues(\.descriptor) ?? [:]
        displayDescriptors = state?.tiles.mapValues(\.displayDescriptor) ?? [:]
        queryIndices = state?.tiles.compactMapValues(\.query) ?? [:]
        instanceCells = state?.instanceCells.mapValues(\.prepared) ?? [:]
        instanceColliders = state?.instanceColliders.mapValues(\.prepared) ?? [:]
        selections = state?.tiles.mapValues(\.selection) ?? [:]
    }

    func accepts(_ current: Terrain3DSource, editID: UUID? = nil, meshEditID: UUID? = nil) -> Bool {
        edit?.id == editID && meshEdit?.id == meshEditID && TerrainSourceKey(source) == TerrainSourceKey(current)
            && source.maximumResidentHeightBytes == current.maximumResidentHeightBytes
            && source.maximumResidentRegions == current.maximumResidentRegions && source.maximumMeshBytes == current.maximumMeshBytes
            && source.maximumLOD == current.maximumLOD
            && source.generatesCollision == current.generatesCollision && source.streamingRadius == current.streamingRadius
            && source.physicsPadding == current.physicsPadding
            && source.instanceCollision == current.instanceCollision && source.queries == current.queries
    }

    var isStale: Bool { storage?.revision != storageRevision || meshEdit?.ticket?.isSuperseded == true }

    @concurrent
    func build() async -> TerrainSourceOutcome {
        if let meshEdit { return await buildMeshEdit(meshEdit) }
        if let edit {
            return await buildHeightEdit(edit)
        }
        do {
            try Task.checkCancellation()
            let requested = TerrainSourceKey(source)
            if loadedKey != requested || residency == nil {
                let cache = try await TerrainRegionCache.open(manifestAt: source.source)
                if cache.manifest.meshDocumentFileName != nil {
                    let build = try await MeshTerrainSourcePreparation.prepare(cache: cache, source: source, request: self,
                                                                              assetOverride: loadedKey == requested ? meshAsset : nil)
                    return .prepared(.init(build: build, key: requested, failure: nil))
                }
            }
            let failure = failedLoad.flatMap { $0.key == requested ? $0 : nil }
            let retained = failure != nil && loadedKey != requested && storage != nil
            let sameData = loadedKey == requested || retained
            let input: TerrainResidencyInput
            if retained, let storage {
                input = .init(storage: storage, target: nil, expectedRevision: nil, residency: residency?.pinning(transactionPins))
            } else {
                input = try await TerrainSourceResidency.prepare(
                    source: source,
                    previous: sameData ? residency : nil,
                    storage: sameData ? storage : nil,
                    focus: focus,
                    matrix: matrix,
                    transactionPins: sameData ? transactionPins : []
                )
            }
            let build = try await Terrain3DSourceSystem.prepare(
                input,
                revisions: sameData ? revisions : [:],
                previousSelections: sameData ? selections : [:],
                cameraPositions: focus.cameras,
                matrix: matrix,
                source: source,
                retainingLOD: retained,
                previousInstanceCells: sameData ? instanceCells : [:],
                previousCanonical: sameData ? canonicalDescriptors : [:],
                previousQueries: sameData ? queryIndices : [:],
                physicsInterests: focus.physics,
                previousInstanceColliders: sameData ? instanceColliders : [:],
                allCameraRegions: focus.allCameraRegions
            )
            try Task.checkCancellation()
            return .prepared(.init(build: build, key: retained ? loadedKey : requested, failure: retained ? failure : nil))
        } catch is CancellationError { return .stale } catch TerrainHeightStorage.StorageError.staleRevision { return .stale } catch TerrainSourceError.changedDuringBuild {
            return .stale
        } catch TerrainSourceError.unsupportedVolumeMaterials {
            let message = TerrainSourceError.unsupportedVolumeMaterials.localizedDescription
            return await retainedOutcome(message: message, failure: .init(key: TerrainSourceKey(source), message: message))
        } catch let error as TerrainManifestLoadFailure {
            return await retainedOutcome(message: error.message, failure: .init(key: TerrainSourceKey(source), message: error.message))
        } catch { return await retainedOutcome(message: error.localizedDescription, failure: nil) }
    }

    private func buildHeightEdit(_ edit: Terrain3DHeightEdit) async -> TerrainSourceOutcome {
        do {
            try Task.checkCancellation()
            guard let storage, storage === edit.storage else { throw TerrainHeightEditError.wrongSurface }
            let geometrySource = residentDiagnostic == nil ? source : residentSettings ?? source
            let footprint = try TerrainAuthoringFootprint(edit: edit, storage: storage, residency: residency, maximumRegions: geometrySource.maximumResidentRegions)
            let hydrated: TerrainResidencyInput
            if let residency, !footprint.regions.isSubset(of: residency.knownRegions) {
                hydrated = try await TerrainSourceResidency.prepare(
                    source: geometrySource,
                    previous: residency,
                    storage: storage,
                    focus: focus,
                    matrix: matrix,
                    transactionPins: transactionPins,
                    authoringRead: footprint.regions
                )
            } else {
                hydrated = .init(storage: storage, target: nil, expectedRevision: nil, residency: residency)
            }
            var activeResidency = hydrated.residency
            let editing = try hydrated.storage.editingSnapshot(regions: footprint.regions, expectedRevision: hydrated.storage.revision)
            let requiresAdmission: Bool
            if let activeResidency {
                requiresAdmission = try activeResidency.needsInstanceAdmission(edit.instanceChanges)
            } else {
                requiresAdmission = !edit.instanceChanges.isEmpty
            }
            let staged: (storage: TerrainHeightStorage, delta: TerrainHeightDelta)
            if let brush = edit.brush {
                staged = try editing.stagedBrush(brush, expectedRevision: editing.revision, plan: footprint.brushPlan)
            } else {
                staged = try editing.stagedHeights(edit.updates, expectedRevision: editing.revision)
            }
            let layers = activeResidency?.cache.manifest.materials.map { Set($0.layers.map(\.id)) }
            var surface = edit.surfaceUpdates, masks = edit.maskUpdates
            if let brush = edit.surfaceBrush, let plan = footprint.surfacePlan {
                let generated = try TerrainSurfaceBrushKernel(source: staged.storage, stroke: brush, plan: plan).evaluate()
                surface = generated.surface; masks = generated.masks
            }
            let painted = try staged.storage.applySurfaceUpdates(
                surface,
                masks: masks,
                layers: layers,
                expectedRevision: staged.storage.revision,
                advanceRevision: staged.storage.revision == editing.revision
            )
            var explicit = edit.instanceChanges
            if let brush = edit.instanceBrush, let plan = footprint.instancePlan {
                explicit = try TerrainInstanceBrushKernel(source: staged.storage, stroke: brush, plan: plan, materials: activeResidency?.cache.manifest.materials).evaluate()
                if brush.settings.operation == .paint {
                    guard let reference = activeResidency?.cache.manifest.meshPrototypes.first(where: { $0.id == brush.settings.prototypeID }) else {
                        throw TerrainInstanceBrushError.missingPrototype
                    }
                    if !explicit.isEmpty, var resident = activeResidency {
                        if resident.prototypes[reference.id] == nil { resident.prototypes[reference.id] = try await resident.cache.loadPrototype(reference) }
                        activeResidency = resident
                    }
                }
            }
            let automatic = try staged.storage.reprojectAnchors(after: staged.delta.changes, excluding: Set(explicit.map(\.coordinate)))
            let authored = try staged.storage.applyInstanceChanges(
                explicit,
                expectedRevision: staged.storage.revision,
                advanceRevision: staged.storage.revision == editing.revision
            )
            try staged.storage.validateNativeRegionBudgets()
            staged.storage.restoreDrawCoverage(activeResidency?.visible ?? Set(storage.regionCoordinates))
            let admitted: TerrainResidencyInput
            let newResources = activeResidency.map { resident in staged.storage.resourceCoordinates.contains { !resident.knownRegions.contains($0) } } ?? false
            if requiresAdmission || newResources {
                admitted = try await TerrainSourceResidency.prepare(
                    source: geometrySource,
                    previous: activeResidency,
                    storage: staged.storage,
                    focus: focus,
                    matrix: matrix,
                    transactionPins: transactionPins
                )
            } else {
                // Staged page/row budgets are already validated. No new region or baseline
                // is introduced, so retain COW placement cells without exporting/reimporting them.
                var current = activeResidency?.pinning(transactionPins)
                current?.admittedRevision = staged.storage.revision
                admitted = .init(storage: staged.storage, target: nil, expectedRevision: nil, residency: current)
            }
            let input = TerrainResidencyInput(
                storage: admitted.storage,
                target: storage,
                expectedRevision: edit.expectedRevision,
                residency: admitted.residency
            )
            let delta = TerrainHeightDelta(
                changes: staged.delta.changes,
                previousRevision: edit.expectedRevision,
                revision: admitted.storage.revision,
                instanceChanges: automatic + authored,
                surfaceChanges: painted.surface,
                maskChanges: painted.masks
            )
            let build = try await Terrain3DSourceSystem.prepare(
                input,
                revisions: revisions,
                previousSelections: selections,
                cameraPositions: focus.cameras,
                matrix: matrix,
                source: geometrySource,
                retainingLOD: residentDiagnostic != nil,
                previousInstanceCells: instanceCells,
                previousCanonical: canonicalDescriptors,
                previousQueries: queryIndices,
                physicsInterests: focus.physics,
                previousInstanceColliders: instanceColliders,
                allCameraRegions: focus.allCameraRegions
            )
            try Task.checkCancellation()
            let failure = failedLoad.flatMap { $0.key == TerrainSourceKey(source) ? $0 : nil }
            return .prepared(
                .init(
                    build: build,
                    key: loadedKey,
                    failure: failure,
                    diagnostic: residentDiagnostic,
                    heightDelta: delta
                )
            )
        } catch is CancellationError { return .stale } catch { return .editFailed(error.localizedDescription) }
    }

    private func retainedOutcome(message: String, failure: TerrainSourceFailedLoad?) async -> TerrainSourceOutcome {
        guard let storage, let residentSettings, let loadedKey else {
            return .failed(message, failure)
        }
        do {
            try Task.checkCancellation()
            let input = TerrainResidencyInput(storage: storage, target: nil, expectedRevision: nil, residency: residency?.pinning(transactionPins))
            let build = try await Terrain3DSourceSystem.prepare(
                input,
                revisions: revisions,
                previousSelections: selections,
                cameraPositions: focus.cameras,
                matrix: matrix,
                source: residentSettings,
                retainingLOD: true,
                previousInstanceCells: instanceCells,
                previousCanonical: canonicalDescriptors,
                previousQueries: queryIndices,
                physicsInterests: focus.physics,
                previousInstanceColliders: instanceColliders,
                allCameraRegions: focus.allCameraRegions
            )
            try Task.checkCancellation()
            return .prepared(.init(build: build, key: loadedKey, failure: failure, diagnostic: message))
        } catch is CancellationError { return .stale } catch { return .failed(message, failure) }
    }
}

struct TerrainSourceProduct: Sendable {
    let build: TerrainSourceBuild
    let key: TerrainSourceKey?
    let failure: TerrainSourceFailedLoad?
    var diagnostic: String?
    var heightDelta: TerrainHeightDelta?
}

enum TerrainSourceOutcome: Sendable {
    case prepared(TerrainSourceProduct)
    case failed(String, TerrainSourceFailedLoad?)
    case editFailed(String)
    case meshEditFailed(String)
    case stale
}

struct TerrainSourcePublication: Sendable {
    let product: TerrainSourceProduct
    var matrix: Transform3D
    let collision: Bool
    var coordinates: [TerrainTileCoordinate]
    var cursor = 0
    var materialArrays: TerrainMaterialTextureArrays?
    var materialUpload: TerrainMaterialUpload?
    var materials: [TerrainTileCoordinate: PBRMaterial] = [:]
    var meshes: [TerrainTileCoordinate: Mesh] = [:]
    var shapes: [TerrainTileCoordinate: Shape3DResource] = [:]
    var instanceCoordinates: [UInt64]?
    var instanceCursor = 0
    var instanceShapes: [UInt64: Shape3DResource] = [:]
}

struct TerrainSourceJobState: Sendable {
    var outcome: TerrainSourceOutcome?
    var publication: TerrainSourcePublication?
    var finished = false
}

final class TerrainSourceJobBox: Sendable {
    let value = Mutex(TerrainSourceJobState())
}

/// This owned task spans frames; removal, supersession and system teardown cancel it.
/// Its result box and incremental publication are synchronized independently of ECS storage.
final class TerrainSourceJob: Sendable {
    let request: TerrainSourceRequest
    let box: TerrainSourceJobBox
    private let task: Task<Void, Never>

    init(request: TerrainSourceRequest) {
        self.request = request
        let box = TerrainSourceJobBox()
        self.box = box
        task = Task {
            let result = await request.build()
            box.value.withLock { $0.outcome = result }
        }
    }

    var isFinished: Bool { box.value.withLock { $0.finished } }
    func cancel() { task.cancel() }
    deinit { task.cancel() }
}
