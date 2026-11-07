import AdaECS
import Foundation

/// One canonical sample value in a height-edit request.
public struct TerrainHeightUpdate: Equatable, Sendable {
    public let point: TerrainGridPoint
    public let height: Float

    public init(point: TerrainGridPoint, height: Float) {
        self.point = point
        self.height = height
    }
}

/// A compact committed sample change, retaining the value needed to undo it.
public struct TerrainHeightChange: Equatable, Sendable {
    public let point: TerrainGridPoint
    public let previousHeight: Float
    public let height: Float
}

/// The committed sample delta for one terrain edit.
public struct TerrainHeightDelta: Sendable {
    public let changes: [TerrainHeightChange]
    public let previousRevision: UInt64
    public let revision: UInt64
    public internal(set) var instanceChanges: [TerrainInstanceCellChange] = []
    public internal(set) var surfaceChanges: [TerrainSurfaceChange] = []
    public internal(set) var maskChanges: [TerrainRuleMaskChange] = []

    public var reversedUpdates: [TerrainHeightUpdate] {
        changes.map { .init(point: $0.point, height: $0.previousHeight) }
    }
}

/// Attach to a loaded Terrain3DSource owner to request one atomic, bounded height edit.
/// The captured storage identity and revision prevent applying it to a replaced or changed surface.
/// Remove the component before publication to cancel the request.
public struct Terrain3DHeightEdit: Component, Sendable {
    public static let maximumUpdates = 65_536
    public let id: UUID
    public let updates: [TerrainHeightUpdate]
    public let brush: TerrainHeightBrushStroke?
    public let instanceChanges: [TerrainInstanceCellChange]
    public let instanceBrush: TerrainInstanceBrushStroke?
    public let surfaceUpdates: [TerrainSurfaceUpdate]
    public let maskUpdates: [TerrainRuleMaskUpdate]
    public let surfaceBrush: TerrainSurfaceBrushStroke?
    public let expectedRevision: UInt64
    let storage: TerrainHeightStorage

    public init(
        storage: TerrainHeightStorage,
        updates: [TerrainHeightUpdate],
        surface: [TerrainSurfaceUpdate] = [],
        masks: [TerrainRuleMaskUpdate] = []
    ) {
        id = UUID()
        self.storage = storage
        self.updates = updates
        brush = nil
        instanceChanges = []
        instanceBrush = nil
        surfaceUpdates = surface
        maskUpdates = masks
        surfaceBrush = nil
        expectedRevision = storage.revision
    }

    public init(storage: TerrainHeightStorage, brush: TerrainHeightBrushStroke) {
        id = UUID()
        self.storage = storage
        updates = []
        self.brush = brush
        instanceChanges = []
        instanceBrush = nil
        surfaceUpdates = []
        maskUpdates = []
        surfaceBrush = nil
        expectedRevision = storage.revision
    }

    /// Captures the inverse height values and exact placement rows of a committed gesture.
    public init(storage: TerrainHeightStorage, undoing delta: TerrainHeightDelta) {
        id = UUID()
        self.storage = storage
        updates = delta.reversedUpdates
        brush = nil
        instanceChanges = delta.instanceChanges.map(\.reversed)
        instanceBrush = nil
        surfaceUpdates = delta.surfaceChanges.map(\.reversedUpdate)
        maskUpdates = delta.maskChanges.map(\.reversedUpdate)
        surfaceBrush = nil
        expectedRevision = storage.revision
    }

    /// Captures one atomic paint/mask gesture alongside the existing authoring channels.
    public init(storage: TerrainHeightStorage, surface: [TerrainSurfaceUpdate], masks: [TerrainRuleMaskUpdate] = []) {
        self.init(storage: storage, updates: [], surface: surface, masks: masks)
    }

    /// Replaces explicit placement cells as one revision-checked gesture.
    public init(storage: TerrainHeightStorage, instances: [TerrainInstanceCellChange]) {
        id = UUID()
        self.storage = storage
        updates = []
        brush = nil
        instanceChanges = instances
        instanceBrush = nil
        surfaceUpdates = []
        maskUpdates = []
        surfaceBrush = nil
        expectedRevision = storage.revision
    }

    /// Captures one deterministic mesh paint/erase gesture for the shared authoring pipeline.
    public init(storage: TerrainHeightStorage, brush: TerrainInstanceBrushStroke) {
        id = UUID()
        self.storage = storage
        updates = []
        self.brush = nil
        instanceChanges = []
        instanceBrush = brush
        surfaceUpdates = []
        maskUpdates = []
        surfaceBrush = nil
        expectedRevision = storage.revision
    }

    /// Captures one layer, rule-mask, tint or roughness brush gesture for atomic publication.
    public init(storage: TerrainHeightStorage, brush: TerrainSurfaceBrushStroke) {
        id = UUID()
        self.storage = storage
        updates = []
        self.brush = nil
        instanceChanges = []
        instanceBrush = nil
        surfaceUpdates = []
        maskUpdates = []
        surfaceBrush = brush
        expectedRevision = storage.revision
    }
}

/// General authoring names; the original height-edit spellings remain source compatible.
public typealias Terrain3DEdit = Terrain3DHeightEdit
public typealias Terrain3DEditStatus = Terrain3DHeightEditStatus
public typealias TerrainEditDelta = TerrainHeightDelta

public enum TerrainHeightEditPhase: Equatable, Sendable {
    case pending, applied, failed, cancelled
}

/// Transient completion state; an applied delta can create the inverse request for Undo.
public struct Terrain3DHeightEditStatus: Component, Sendable {
    public let id: UUID
    public let phase: TerrainHeightEditPhase
    public let error: String?
    public let delta: TerrainHeightDelta?
}

public enum TerrainHeightEditError: LocalizedError {
    case tooManyUpdates, duplicateSample, invalidHeight, invalidCoordinate
    case missingSurface, staleRevision, wrongSurface, heightBudgetExceeded, sourceUnavailable, sourceConfigurationChanged

    public var errorDescription: String? {
        switch self {
        case .tooManyUpdates: "Terrain height edit exceeds 65536 samples"
        case .duplicateSample: "Height edit contains duplicate sample addresses"
        case .invalidHeight: "Height edit contains a nonfinite height"
        case .invalidCoordinate: "Height edit sample lies outside the supported grid"
        case .missingSurface: "Height edit requires a resident terrain surface"
        case .staleRevision: "Terrain changed after the edit was captured"
        case .wrongSurface: "Height edit belongs to a different terrain resource"
        case .heightBudgetExceeded: "Height edit exceeds the resident height-page budget"
        case .sourceUnavailable: "Height edits require a loaded terrain source"
        case .sourceConfigurationChanged: "Publish the requested terrain settings before editing this surface"
        }
    }
}

extension Terrain3DSourceSystem {
    static func heightEditFailure(_ edit: Terrain3DHeightEdit, state: TerrainSourceState?, source: Terrain3DSource) -> TerrainHeightEditError? {
        guard let state, let storage = state.storage, state.key != nil else {
            return .sourceUnavailable
        }
        guard storage === edit.storage else {
            return .wrongSurface
        }
        guard storage.revision == edit.expectedRevision else {
            return .staleRevision
        }
        let requested = TerrainSourceKey(source)
        guard state.key == requested || state.failedLoad?.key == requested else {
            return .sourceUnavailable
        }
        guard hasPublishedHeightEditConfiguration(state, source: source) else {
            return .sourceConfigurationChanged
        }
        return nil
    }

    static func hasPublishedHeightEditConfiguration(_ state: TerrainSourceState, source: Terrain3DSource) -> Bool {
        guard var published = state.publishedSettings else {
            return false
        }
        // A failed URI replacement still permits editing the retained generation. Color and the
        // upload budget are presentation/scheduling controls, independent of residency admission.
        published.source = source.source
        published.reloadGeneration = source.reloadGeneration
        published.color = source.color
        published.maximumTileUpdatesPerFrame = source.maximumTileUpdatesPerFrame
        return published == source
    }

    static func finishHeightEdit(
        _ edit: Terrain3DHeightEdit,
        phase: TerrainHeightEditPhase,
        error: String? = nil,
        delta: TerrainHeightDelta? = nil,
        owner: Entity
    ) {
        let current = owner.components[Terrain3DHeightEdit.self]
        guard current?.id == edit.id || owner.components[Terrain3DHeightEditStatus.self]?.id == edit.id else {
            return
        }
        if current?.id == edit.id { owner.components.remove(Terrain3DHeightEdit.self) }
        owner.components[Terrain3DHeightEditStatus.self] = .init(id: edit.id, phase: phase, error: error, delta: delta)
    }

    static func restoreSourceStatus(_ owner: Entity, source: Terrain3DSource) {
        let state = owner.components[TerrainSourceState.self]
        let hasSurface = state?.meshAsset != nil || (state?.storage != nil && state?.storage?.revision == state?.revision)
        let ready =
            hasSurface && state?.key == TerrainSourceKey(source) && state?.diagnostic == nil
            && state?.matrix == worldMatrix(owner)
            && state.map { hasPublishedHeightEditConfiguration($0, source: source) } == true
        let warnings = state?.meshMaterials?.maps.warnings ?? state?.residency?.materialMaps?.warnings
            ?? owner.components[Terrain3DSourceStatus.self]?.warnings ?? []
        owner.components[Terrain3DSourceStatus.self] = .init(
            isReady: ready, tileCount: state?.tiles.count ?? 0, error: state?.diagnostic, warnings: warnings, instanceColliderCount: state?.instanceColliders.count ?? 0
        )
    }
}
