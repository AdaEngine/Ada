import AdaAssets
import AdaECS
import AdaGeometry
@_spi(Internal) import AdaRender
import AdaTransform
import Foundation
import Math

extension TerrainSourceRequest {
    func buildMeshEdit(_ edit: MeshTerrain3DEdit) async -> TerrainSourceOutcome {
        do {
            try Task.checkCancellation()
            guard edit.ticket?.isSuperseded != true else { return .stale }
            guard let meshAsset, loadedKey == TerrainSourceKey(source),
                edit.expectedInputKey == (try meshAsset.authoringKey()), edit.candidate.document.id == meshAsset.document.id,
                edit.sourceTransforms.count <= 512, Set(edit.sourceTransforms.map(\.entity)).count == edit.sourceTransforms.count else {
                throw TerrainSourceError.changedDuringBuild
            }
            for pose in edit.sourceTransforms { _ = try pose.resolvedPose() }
            let candidate: MeshTerrainDocumentAsset
            if (try? edit.candidate.acceptedCompiledProduct()) != nil { candidate = edit.candidate }
            else { candidate = try await edit.candidate.compiling(using: meshEvaluator ?? .init()) }
            try Task.checkCancellation()
            var cache = try await TerrainRegionCache.open(manifestAt: source.source)
            if let path = edit.adoptionManifest {
                let original = URL(fileURLWithPath: source.source).resolvingSymlinksInPath().standardizedFileURL
                let destination = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                // Relative material and prototype references keep their meaning only in the same asset directory.
                guard destination.pathExtension.lowercased() == "aterrain",
                    destination.deletingLastPathComponent() == original.deletingLastPathComponent() else {
                    throw TerrainSourceError.changedDuringBuild
                }
                let staged = try await TerrainRegionCache.open(manifestAt: path)
                let previous = cache.manifest, next = staged.manifest
                guard let name = next.meshDocumentFileName, previous.meshDocumentFileName != nil,
                    previous.spacing == next.spacing, previous.originX == next.originX, previous.originZ == next.originZ,
                    previous.heightRegions == next.heightRegions, previous.volumeFileName == next.volumeFileName else {
                    throw TerrainSourceError.changedDuringBuild
                }
                let disk = try await AssetsManager.loadFresh(MeshTerrainDocumentAsset.self, at: TerrainRegionCache.resourcePath(name, manifestPath: path))
                _ = try disk.acceptedCompiledProduct()
                guard try disk.authoringKey() == candidate.authoringKey(), disk.compiled == candidate.compiled else {
                    throw TerrainSourceError.changedDuringBuild
                }
                // Validate newly registered prototypes even when no cell uses them yet.
                let previousPrototypes = Dictionary(uniqueKeysWithValues: previous.meshPrototypes.map { ($0.id, $0) })
                for prototype in next.meshPrototypes where previousPrototypes[prototype.id] != prototype {
                    _ = try await staged.loadPrototype(prototype)
                }
                // Texture/prototype edits use the staged, validated manifest.
                // The old resource and its dependencies stay live until publication.
                cache = staged
            }
            let build = try await MeshTerrainSourcePreparation.prepare(cache: cache, source: source, request: self, assetOverride: candidate)
            guard edit.ticket?.isSuperseded != true else { return .stale }
            return .prepared(.init(build: build, key: loadedKey, failure: nil))
        } catch is CancellationError { return .stale }
        catch { return .meshEditFailed(error.localizedDescription) }
    }
}

extension Terrain3DSourceSystem {
    static func finishMeshEdit(_ request: MeshTerrain3DEdit, phase: MeshTerrainEditPhase, error: String? = nil, owner: Entity) {
        let current = owner.components[MeshTerrain3DEdit.self]?.id
        guard current == nil || current == request.id else { return }
        if current == request.id { owner.components.remove(MeshTerrain3DEdit.self) }
        owner.components[MeshTerrain3DEditStatus.self] = .init(id: request.id, phase: phase, error: error)
    }

    static func cancelMeshPreview(_ request: MeshTerrain3DEdit, source: Terrain3DSource, owner: Entity) {
        guard owner.components[MeshTerrain3DEdit.self]?.id == request.id else { return }
        finishMeshEdit(request, phase: .cancelled, owner: owner)
        restoreSourceStatus(owner, source: source)
    }

    static func validateMeshEditPublication(_ request: MeshTerrain3DEdit, owner: Entity, world: World) throws -> MeshTerrainEditPublication {
        guard owner.components[MeshTerrain3DEdit.self]?.id == request.id,
            let asset = owner.components[TerrainSourceState.self]?.meshAsset, try asset.authoringKey() == request.expectedInputKey,
            request.sourceTransforms.allSatisfy({ $0.entity != owner.id && world.getEntityByID($0.entity) != nil }) else {
            throw TerrainSourceError.changedDuringBuild
        }
        if let replacements = request.drawReplacements {
            guard replacements.count <= 512, Set(replacements.map(\.entity)).count == replacements.count else { throw TriangleGeometryError.budgetExceeded }
            for replacement in replacements {
                guard replacement.entity != owner.id, let source = world.getEntityByID(replacement.entity),
                    let mesh = source.components[Mesh3DComponent.self]?.mesh,
                    source.components[SkinnedMesh3DComponent.self] == nil, source.components[MorphWeights3DComponent.self] == nil,
                    source.components[MeshTerrain3DSourceMask.self].map({ $0.owner == owner.id }) ?? true,
                    replacement.parts.count <= 64,
                    replacement.parts.allSatisfy({ mesh.models.indices.contains($0.model) && mesh.models[$0.model].parts.indices.contains($0.part) }) else {
                    throw TriangleGeometryError.invalidInput
                }
            }
        }
        if let selected = request.collisionReplacements { try MeshTerrainSourceCollisionOwnership.validate(selected, owner: owner, world: world) }
        try MeshTerrainBindingLifecycle.validate(request.bindingChanges, owner: owner, world: world)
        return try .init(poses: request.sourceTransforms.map { try $0.resolvedPose() }, bindings: MeshTerrainBindingUpdates.prepare(request, owner: owner, world: world))
    }

    static func publishMeshSourcePoses(_ request: MeshTerrain3DEdit, poses: [Transform], world: World) {
        for (source, pose) in zip(request.sourceTransforms, poses) { world.getEntityByID(source.entity)?.components[Transform.self] = pose }
    }

    static func publishMeshResourceAdoption(_ request: MeshTerrain3DEdit, owner: Entity) {
        guard let path = request.adoptionManifest, var source = owner.components[Terrain3DSource.self],
            var state = owner.components[TerrainSourceState.self] else { return }
        source.source = path
        state.key = TerrainSourceKey(source)
        state.attempted.source = path
        state.publishedSettings?.source = path
        state.failedLoad = nil
        owner.components[Terrain3DSource.self] = source
        owner.components[TerrainSourceState.self] = state
    }

    static func publishMeshSourceDraws(_ request: MeshTerrain3DEdit, owner: Entity, world: World) {
        guard let replacements = request.drawReplacements, var state = owner.components[TerrainSourceState.self] else { return }
        let next = Set(replacements.map(\.entity))
        for id in state.meshMaskedSources.subtracting(next) {
            if let source = world.getEntityByID(id), source.components[MeshTerrain3DSourceMask.self]?.owner == owner.id {
                source.components.remove(MeshTerrain3DSourceMask.self)
            }
        }
        for replacement in replacements {
            guard let source = world.getEntityByID(replacement.entity) else { continue }
            let current = source.components[MeshTerrain3DSourceMask.self]
            if current?.owner != owner.id || current?.parts != replacement.parts {
                source.components[MeshTerrain3DSourceMask.self] = .init(owner: owner.id, parts: replacement.parts)
            }
        }
        state.meshMaskedSources = next
        owner.components[TerrainSourceState.self] = state
    }
}
