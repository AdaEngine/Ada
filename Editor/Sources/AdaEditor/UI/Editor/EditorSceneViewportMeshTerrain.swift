@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

extension EditorSceneViewportModel {
    func joinSelectedMeshTerrain() {
        let operation: MeshTerrainModifierOperation
        switch terrainEditing.meshOperation {
        case "Subtract": operation = .subtract
        case "Conform":
            operation = .conform(direction: [0, -1, 0], distance: terrainEditing.meshConformDistance, strength: terrainEditing.meshConformStrength)
        default: operation = .union
        }
        applyMeshTerrainBinding(.join(.init(targetEditorID: terrainEditing.meshTargetEditorID, parts: terrainEditing.meshSelectedParts,
            operation: operation, contactWidth: terrainEditing.meshContactWidth)))
    }

    func detachSelectedMeshTerrain() {
        applyMeshTerrainBinding(.detach)
    }

    private func applyMeshTerrainBinding(_ command: MeshTerrainBindingCommand) {
        guard !terrainEditing.isSourceBusy, let context = terrainSourceContext, let baseline = sceneModel,
            let sourceID = selectedEditorID else { return }
        terrainEditing.sourceGeneration = UUID()
        let generation = terrainEditing.sourceGeneration
        terrainEditing.isSourceBusy = true
        terrainEditing.sourceFailure = nil
        terrainEditing.sourceTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishSourceTerrainTask(generation: generation) }
            do {
                let snapshot = try await context.application.withWorldAccess {
                    switch command {
                    case let .join(options):
                        try self.captureMeshTerrainJoin(sourceID: sourceID, baseline: baseline, options: options, application: context.application)
                    case .detach:
                        try self.captureMeshTerrainDetach(sourceID: sourceID, baseline: baseline, application: context.application)
                    }
                }
                try await EditorMeshTerrainTransaction.run(snapshot.input, application: context.application,
                    isCurrent: { self.terrainEditing.sourceGeneration == generation && self.matchesMeshTerrainBaseline(baseline) },
                    onProgress: { self.terrainEditing.sourceStatus = $0 },
                    commit: { file in
                        guard self.matchesMeshTerrainBaseline(baseline), var model = self.sceneModel,
                            let targetIndex = model.entities.firstIndex(where: { $0.id == snapshot.targetEditorID }),
                            let sourceIndex = model.entities.firstIndex(where: { $0.id == sourceID }) else {
                            throw EditorTerrainSourceAuthoring.Failure.sourceChanged
                        }
                        let root = context.assetsRoot.resolvingSymlinksInPath().standardizedFileURL
                        let path = file.resolvingSymlinksInPath().standardizedFileURL.path
                        guard path.hasPrefix(root.path + "/") else { throw EditorTerrainSourceAuthoring.Failure.sourceChanged }
                        model.entities[targetIndex].components[EditorBuiltInComponentType.terrain3DSource]?["source"] = .string("@res://" + path.dropFirst(root.path.count + 1))
                        model.entities[sourceIndex].components[String(reflecting: MeshTerrain3DIdentity.self)] = try snapshot.identity.map(Self.meshPayload)
                        model.entities[sourceIndex].components[String(reflecting: MeshTerrain3DBinding.self)] = try snapshot.binding.map(Self.meshPayload)
                        self.sceneModel = model
                        self.publishTerrainDocument()
                        self.refreshTerrainSourceControls()
                        self.onSelectionChanged?(self.selectedEntityViewModel(editorID: self.selectedEditorID, model: model))
                    })
            } catch is CancellationError {
            } catch {
                if self.terrainEditing.sourceGeneration == generation {
                    self.terrainEditing.sourceStatus = "Mesh Terrain could not be updated."
                    self.terrainEditing.sourceFailure = error.localizedDescription
                }
            }
        }
    }

    private struct MeshTerrainJoinSnapshot {
        let targetEditorID: String
        let identity: MeshTerrain3DIdentity?
        let binding: MeshTerrain3DBinding?
        let input: EditorMeshTerrainTransaction.Input
    }

    private enum MeshTerrainBindingCommand: Sendable {
        case join(MeshTerrainJoinOptions)
        case detach
    }

    private struct MeshTerrainJoinOptions: Sendable {
        let targetEditorID: String?
        let parts: [MeshTerrainPartSelection]
        let operation: MeshTerrainModifierOperation
        let contactWidth: Float
    }

    private func captureMeshTerrainJoin(sourceID: String, baseline: EditorSceneModel, options: MeshTerrainJoinOptions, application: AppWorlds) throws -> MeshTerrainJoinSnapshot {
        guard matchesMeshTerrainBaseline(baseline), let root = runtimeEntity(for: sourceID),
            let source = baseline.entities.first(where: { $0.id == sourceID }) else { throw EditorTerrainSourceAuthoring.Failure.unavailable }
        let previousBinding = root.components[MeshTerrain3DBinding.self]
        let targets = baseline.entities.compactMap { entity -> (String, Entity)? in
            guard entity.id != sourceID, let owner = runtimeEntity(for: entity.id), owner.components[MeshTerrain3DSourceSurface.self] != nil,
                owner.components[MeshTerrain3DIdentity.self] != nil else { return nil }
            return (entity.id, owner)
        }
        let selected: (String, Entity)?
        if let targetID = options.targetEditorID {
            guard let explicit = targets.first(where: { $0.0 == targetID }) else {
                throw EditorTerrainSourceAuthoring.Failure.failed("The selected Mesh Terrain is unavailable. Choose another terrain.")
            }
            selected = explicit
        } else if let binding = previousBinding {
            selected = targets.first { $0.1.components[MeshTerrain3DIdentity.self]?.id == binding.target }
        } else { selected = targets.first }
        guard let (targetID, owner) = selected, let targetIdentity = owner.components[MeshTerrain3DIdentity.self],
            let asset = owner.components[MeshTerrain3DSourceSurface.self]?.asset, let settings = owner.components[Terrain3DSource.self],
            previousBinding == nil || previousBinding?.target == targetIdentity.id,
            let rootMatrix = EditorPicking.worldMatrix(for: root, requiringVisible: true),
            let targetMatrix = EditorPicking.worldMatrix(for: owner, requiringVisible: true) else {
            throw EditorTerrainSourceAuthoring.Failure.unavailable
        }
        let captured = try MeshTerrainSourceCapture.capture(root, parts: options.parts)
        let identity = root.components[MeshTerrain3DIdentity.self] ?? .init()
        let used = Set(asset.document.modifiers.map(\.sourceID))
        guard let next = previousBinding?.sourceID ?? (UInt32(1)...UInt32(513)).first(where: { !used.contains($0) }) else {
            throw TriangleGeometryError.budgetExceeded
        }
        let operation = options.operation
        let binding = MeshTerrain3DBinding(target: targetIdentity.id, modifier: previousBinding?.modifier ?? UUID(), sourceID: next,
            operation: operation, parts: options.parts, contactWidth: options.contactWidth)
        let ownership = try MeshTerrain3DOwnership.capture(of: owner, in: application.main)
        let oldParts = try previousBinding.map { try MeshTerrainSourceCapture.capture(root, parts: $0.parts).drawReplacements } ?? []
        let oldDraws = Set(oldParts.map(\.entity))
        let previousDraws = ownership.draws.filter { oldDraws.contains($0.entity) }
        let possibleCollisions = try MeshTerrainSourceCapture.collisionSources(root, parts: previousBinding?.parts ?? [], in: application.main)
        let oldCollisions = Set(ownership.collisions).intersection(possibleCollisions)
        let collision = settings.generatesCollision && application.main.physicsWorld3D != nil
        let selectedCollisions = operation == .union && collision
            ? try MeshTerrainSourceCapture.collisionSources(root, parts: binding.parts, in: application.main) : []
        let selectedDraws = operation == .union ? captured.drawReplacements : []
        let draws = ownership.draws.filter { !oldDraws.contains($0.entity) } + selectedDraws
        let collisions = Set(ownership.collisions).subtracting(oldCollisions).union(selectedCollisions).sorted()
        var document = asset.document
        let existing = document.modifiers.firstIndex { $0.id == binding.modifier }
        let retained = existing.map { document.modifiers[$0] }
        let modifier = MeshTerrainModifier(id: binding.modifier, sourceID: binding.sourceID, operation: operation, surface: captured.surface,
            transform: targetMatrix.inverse * rootMatrix, order: retained?.order ?? document.modifiers.count,
            entityID: identity.id, sourcePath: source.components[EditorBuiltInComponentType.model3DSource]?["source"]?.stringValue ?? retained?.sourcePath,
            materialLayer: retained?.materialLayer, contactWidth: binding.contactWidth,
            rounding: operation == .union ? retained?.rounding : nil, sourceAppearance: operation == .union ? captured.appearance : nil)
        if let existing { document.modifiers[existing] = modifier } else { document.modifiers.append(modifier) }
        let candidate = MeshTerrainDocumentAsset(document: document, populationRules: asset.populationRules,
            manualPlacements: asset.manualPlacements, populationOverrides: asset.populationOverrides)
        let update = MeshTerrainBindingUpdate(entity: root.id, modifier: binding.modifier, identity: identity, binding: binding,
            draws: Set(selectedDraws.map(\.entity)), collisions: Set(selectedCollisions))
        let previous = MeshTerrainBindingUpdate(entity: root.id, modifier: binding.modifier,
            identity: root.components[MeshTerrain3DIdentity.self], binding: previousBinding,
            draws: Set(previousDraws.map(\.entity)), collisions: oldCollisions)
        return .init(targetEditorID: targetID, identity: identity, binding: binding,
            input: .init(owner: owner, original: settings, previous: asset, candidate: candidate, previousOwnership: ownership,
                draws: draws, collisions: collisions, bindings: [update], previousBindings: [previous]))
    }

    private func captureMeshTerrainDetach(sourceID: String, baseline: EditorSceneModel, application: AppWorlds) throws -> MeshTerrainJoinSnapshot {
        guard matchesMeshTerrainBaseline(baseline), let root = runtimeEntity(for: sourceID), let binding = root.components[MeshTerrain3DBinding.self],
            let target = baseline.entities.first(where: { runtimeEntity(for: $0.id)?.components[MeshTerrain3DIdentity.self]?.id == binding.target }),
            let owner = runtimeEntity(for: target.id), let asset = owner.components[MeshTerrain3DSourceSurface.self]?.asset,
            let settings = owner.components[Terrain3DSource.self] else { throw EditorTerrainSourceAuthoring.Failure.unavailable }
        let identity = root.components[MeshTerrain3DIdentity.self]
        let ownership = try MeshTerrain3DOwnership.capture(of: owner, in: application.main)
        let sourceOwnership = try MeshTerrain3DOwnership.capture(of: owner, for: root, in: application.main)
        let oldDraws = Set(sourceOwnership.draws.map(\.entity)), oldCollisions = Set(sourceOwnership.collisions)
        var document = asset.document
        document.modifiers.removeAll { $0.id == binding.modifier }
        let candidate = MeshTerrainDocumentAsset(document: document, populationRules: asset.populationRules,
            manualPlacements: asset.manualPlacements, populationOverrides: asset.populationOverrides)
        let detached = MeshTerrainBindingUpdate(entity: root.id, modifier: binding.modifier, identity: identity, binding: nil)
        let previous = MeshTerrainBindingUpdate(entity: root.id, modifier: binding.modifier, identity: identity, binding: binding,
            draws: oldDraws, collisions: oldCollisions)
        return .init(targetEditorID: target.id, identity: identity, binding: nil,
            input: .init(owner: owner, original: settings, previous: asset, candidate: candidate, previousOwnership: ownership,
                draws: ownership.draws.filter { !oldDraws.contains($0.entity) }, collisions: ownership.collisions.filter { !oldCollisions.contains($0) },
                bindings: [detached], previousBindings: [previous]))
    }

    private func matchesMeshTerrainBaseline(_ baseline: EditorSceneModel) -> Bool {
        var current = sceneModel, expected = baseline
        current?.editor = nil; expected.editor = nil
        return current == expected
    }

    private static func meshPayload<Value: Encodable>(_ value: Value) throws -> EditorComponentPayload {
        try JSONDecoder().decode(EditorComponentPayload.self, from: JSONEncoder().encode(value))
    }
}
