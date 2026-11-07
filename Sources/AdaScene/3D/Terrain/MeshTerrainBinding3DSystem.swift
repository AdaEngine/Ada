import AdaAssets
import AdaECS
import AdaGeometry
@_spi(Internal) import AdaPhysics
import AdaTransform
import Foundation
import Math

struct MeshTerrainBindingSignature: Equatable, Sendable {
    let binding: MeshTerrain3DBinding
    let relative: Transform3D
    let localPose: Transform
    let parts: [MeshTerrainPartGeneration]
    let collision: Bool
}

struct MeshTerrainBindingState: Component, Sendable {
    var signature: MeshTerrainBindingSignature
    var editID: UUID?
    var proposalID: UUID?
    var masked: Set<Entity.ID>
    var collisions: Set<Entity.ID>
    var acceptedPose: Transform
    var acceptedDocumentKey: Data?
}

/// Captures scene data at a world boundary; workers receive only immutable geometry.
@PlainSystem(dependencies: [.after(Model3DSourceSystem.self), .before(Terrain3DSourceSystem.self)])
struct MeshTerrainBinding3DSystem {
    @Query<Entity, MeshTerrain3DBinding> private var bindings
    @Query<Entity, MeshTerrain3DIdentity> private var identities
    @Query<Entity, TerrainSourceState> private var owners
    @Commands private var commands

    init(world _: World) {}

    func update(context _: UpdateContext) {
        var targets: [UUID: Entity.ID] = [:], duplicates: Set<UUID> = []
        identities.forEach { entity, identity in
            if targets.updateValue(entity.id, forKey: identity.id) != nil { duplicates.insert(identity.id) }
        }
        for duplicate in duplicates { targets.removeValue(forKey: duplicate) }
        owners.forEach { owner, state in
            guard !state.meshBindings.isEmpty else { return }
            let id = owner.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id) else { return }
                do { try MeshTerrainBindingLifecycle.reconcile(owner, world: world) }
                catch {
                    // Retain the accepted generation and expose a recoverable diagnostic.
                    if let status = owner.components[Terrain3DSourceStatus.self] {
                        owner.components[Terrain3DSourceStatus.self] = .init(isReady: status.isReady, tileCount: status.tileCount,
                            error: error.localizedDescription, preparedTileCount: status.preparedTileCount,
                            pendingTileCount: status.pendingTileCount, isPreparing: status.isPreparing,
                            warnings: status.warnings, instanceColliderCount: status.instanceColliderCount)
                    }
                }
            }
        }
        bindings.forEach { source, binding in
            let sourceID = source.id, targetID = targets[binding.target]
            commands.queue.push { world in
                guard let source = world.getEntityByID(sourceID), source.components[MeshTerrain3DBinding.self] == binding else { return }
                guard let targetID, let target = world.getEntityByID(targetID), target !== source,
                    target.components[Terrain3DSource.self] != nil else {
                    source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .orphaned, error: "Terrain binding target is missing or ambiguous")
                    return
                }
                do { try Self.reconcile(source: source, target: target, binding: binding, world: world) }
                catch {
                    source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .failed, error: error.localizedDescription)
                }
            }
        }
    }

    private static func reconcile(source: Entity, target: Entity, binding: MeshTerrain3DBinding, world: World) throws {
        guard let asset = target.components[MeshTerrain3DSourceSurface.self]?.asset else {
            let ready = target.components[Terrain3DSourceStatus.self]?.isReady == true
            source.components[MeshTerrain3DBindingStatus.self] = .init(phase: ready ? .orphaned : .pending,
                error: ready ? "Binding target is not a mesh terrain" : nil)
            return
        }
        var state = source.components[MeshTerrainBindingState.self]
        if let editID = state?.editID, let status = target.components[MeshTerrain3DEditStatus.self], status.id == editID, status.phase != .pending {
            state?.editID = nil
            if status.phase == .applied {
                if source.components[MeshTerrain3DProposedPose.self]?.id == state?.proposalID { source.components.remove(MeshTerrain3DProposedPose.self) }
                state?.acceptedPose = source.components[Transform.self] ?? .init()
                state?.acceptedDocumentKey = asset.compiled?.inputKey
                source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .applied, error: nil)
            } else if status.phase == .cancelled {
                source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .pending, error: nil)
            } else {
                source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .failed, error: status.error)
            }
            source.components[MeshTerrainBindingState.self] = state
        }
        let currentPose = source.components[Transform.self] ?? .init()
        var proposal = source.components[MeshTerrain3DProposedPose.self]
        if proposal?.ticket?.isSuperseded == true {
            source.components.remove(MeshTerrain3DProposedPose.self)
            return
        }
        if proposal == nil, let accepted = state?.acceptedPose, accepted != currentPose {
            proposal = .init(currentPose)
            source.components[MeshTerrain3DProposedPose.self] = proposal
            source.components[Transform.self] = accepted
        }
        let pose = proposal?.pose ?? currentPose
        _ = try MeshTerrainSourceTransform(entity: source.id, pose: pose).resolvedPose()
        let parentID = source.components[RelationshipComponent.self]?.parent
        let parentMatrix = parentID.flatMap { world.getEntityByID($0) }.map { Terrain3DSourceSystem.worldMatrix($0) } ?? .identity
        let terrainMatrix = Terrain3DSourceSystem.worldMatrix(target)
        try ScalarSolid.validateTransform(terrainMatrix)
        let relative = terrainMatrix.inverse * parentMatrix * pose.matrix
        let parts = binding.enabled ? try MeshTerrainSourceCapture.collect(source, selections: binding.parts) : []
        let collision = target.components[Terrain3DSource.self]?.generatesCollision == true && world.getResource(Physics3DWorldHolder.self) != nil
        if try MeshTerrainBindingLifecycle.waitsForPreviousOwner(source: source, target: target, parts: parts, world: world) {
            source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .pending, error: nil)
            return
        }
        let signature = MeshTerrainBindingSignature(binding: binding, relative: relative, localPose: pose, parts: MeshTerrainSourceCapture.generations(parts), collision: collision)
        if state?.signature == signature, state?.acceptedDocumentKey == asset.compiled?.inputKey,
            state?.proposalID == proposal?.id || source.components[MeshTerrain3DBindingStatus.self]?.phase == .applied {
            if state?.editID == nil, source.components[MeshTerrain3DBindingStatus.self]?.phase == .applied,
                let proposal, proposal.pose == currentPose { source.components.remove(MeshTerrain3DProposedPose.self) }
            return
        }
        // Different bound objects serialize against one accepted document. A new
        // pose of this source may supersede its own in-flight request.
        if let busy = target.components[MeshTerrain3DEdit.self], busy.id != state?.editID { return }
        var document = asset.document
        let existing = document.modifiers.firstIndex { $0.id == binding.modifier }
        var replacements = target.components[TerrainSourceState.self]?.meshMaskedSources.compactMap { id -> MeshTerrainDrawReplacement? in
            guard !(state?.masked.contains(id) ?? false), let mask = world.getEntityByID(id)?.components[MeshTerrain3DSourceMask.self] else { return nil }
            return .init(entity: id, parts: mask.parts)
        } ?? []
        var selected: Set<Entity.ID> = [], selectedCollision: Set<Entity.ID> = []
        var collisions = target.components[TerrainSourceState.self]?.meshCollisionSources.subtracting(state?.collisions ?? []) ?? []
        if binding.enabled {
            let captured = try MeshTerrainSourceCapture.assemble(parts)
            let retained = existing.map { document.modifiers[$0] }
            let portablePath = MeshTerrainSourceCapture.portableModelPath(source)
            let modifier = MeshTerrainModifier(id: binding.modifier, sourceID: binding.sourceID, operation: binding.operation,
                surface: captured.surface, transform: relative, order: retained?.order ?? document.modifiers.count,
                entityID: source.components[MeshTerrain3DIdentity.self]?.id, sourcePath: portablePath ?? retained?.sourcePath,
                materialLayer: retained?.materialLayer, contactWidth: binding.contactWidth,
                rounding: binding.operation == .union ? retained?.rounding : nil,
                sourceAppearance: binding.operation == .union && (TriangleMeshBoolean.isAvailable || retained?.sourceAppearance != nil) ? captured.appearance : nil)
            if let existing { document.modifiers[existing] = modifier } else { document.modifiers.append(modifier) }
            if case .union = binding.operation {
                replacements += captured.drawReplacements
                selected = Set(captured.drawReplacements.map(\.entity))
                if collision { selectedCollision = Set(try MeshTerrainSourceCollisionOwnership.sources(root: source, parts: parts, world: world)) }
            }
        } else if let existing { document.modifiers[existing].enabled = false }
        let candidate = MeshTerrainDocumentAsset(document: document, populationRules: asset.populationRules,
            manualPlacements: asset.manualPlacements, populationOverrides: asset.populationOverrides, compiled: document == asset.document ? asset.compiled : nil)
        try candidate.validate()
        collisions.formUnion(selectedCollision)
        var request = MeshTerrain3DEdit(expectedInputKey: try asset.authoringKey(), candidate: candidate,
            sourceTransforms: [.init(entity: source.id, pose: pose)], drawReplacements: replacements,
            collisionReplacements: collisions.sorted(), ticket: proposal?.ticket)
        request.bindingChanges = [.init(modifier: binding.modifier, source: source.id, draws: selected, collisions: selectedCollision)]
        target.components[MeshTerrain3DEdit.self] = request
        source.components[MeshTerrainBindingState.self] = MeshTerrainBindingState(signature: signature, editID: request.id,
            proposalID: proposal?.id, masked: selected, collisions: selectedCollision, acceptedPose: state?.acceptedPose ?? currentPose, acceptedDocumentKey: asset.compiled?.inputKey)
        source.components[MeshTerrain3DBindingStatus.self] = .init(phase: .pending, error: nil)
    }
}
