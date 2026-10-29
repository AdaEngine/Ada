import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

/// Retains camera-independent geometry. Component-owned revisions also catch edits between
/// two extractions in the same ECS tick, including edits through a component's mutable query.
struct Model3DExtractionCache: Resource {
    private struct Entry {
        var index: Int
        var meshRevision: RID
        var lodRevision: RID?
        var localBounds: AABB?
        var isStatic: Bool
    }
    private var worldID: World.ID?
    private var entries: [Entity.ID: Entry] = [:]
    private var seen: [Bool] = []
    private var materialOwners: [Entity.ID: RID] = [:]
    private var uniqueMaterials: [RID: Material] = [:]
    private(set) var geometryBuildCount = 0

    mutating func extract(
        sourceWorldID: World.ID?,
        elapsed: Float,
        query: Query<Entity, Mesh3DComponent, GlobalTransform>,
        lods: Query<Entity, MeshLOD3DComponent>,
        visibility: Query<Entity, Visibility>,
        noCulling: Query<Entity, NoFrustumCulling>,
        hierarchy: Query<Entity, RelationshipComponent>,
        skins: Query<Entity, SkinnedMesh3DComponent>,
        morphs: Query<Entity, MorphWeights3DComponent>,
        sources: inout ExtractedMesh3DSources,
        animatedBounds: inout AnimatedBounds3D,
        skinning: inout Skinning3DUniforms,
        morphUniforms: inout Morph3DUniforms,
        materials: inout PBR3DUniforms,
        device: RenderDevice,
        drawPass: Model3DDrawPass
    ) {
        if worldID != sourceWorldID {
            entries.removeAll(keepingCapacity: true)
            sources.meshes.removeAll(keepingCapacity: true)
            seen.removeAll(keepingCapacity: true)
            materialOwners.removeAll(keepingCapacity: true)
            uniqueMaterials.removeAll(keepingCapacity: true)
            worldID = sourceWorldID
        }
        for index in seen.indices { seen[index] = false }
        animatedBounds.beginFrame()
        skinning.beginFrame(device: device)
        morphUniforms.beginFrame()
        materials.beginFrame()

        var lodByEntity: [Entity.ID: MeshLOD3DComponent] = [:]
        lods.batched().forEach { entity, lod in lodByEntity[entity.id] = lod }
        var morphByEntity: [Entity.ID: [Float]] = [:]
        morphs.batched().forEach { entity, morph in morphByEntity[entity.id] = morph.weights }
        var posedBounds: [Entity.ID: AABB] = [:]
        var skinScale: [Entity.ID: Float] = [:]
        skins.batched().forEach { entity, skin in
            let revision = SkinningPoseRevision(id: skin.paletteID, generation: skin.poseGeneration)
            // Atmospheres keep the positive instance-Y channel for their own parameters.
            let isAtmosphere = entity.components[Mesh3DComponent.self]?.materials.contains { $0 is AtmosphereMaterial } == true
            if isAtmosphere { _ = skinning.write(skin.matrices, for: entity.id, device: device, revision: revision) }
            else { _ = skinning.writePacked(skin.matrices, for: entity.id, device: device, revision: revision) }
            guard let mesh = entity.components[Mesh3DComponent.self]?.mesh else { return }
            let lod = lodByEntity[entity.id]
            let meshes = lod?.skeletonCompatible == true ? [mesh] + (lod?.alternatives ?? []) : [mesh]
            posedBounds[entity.id] = animatedBounds.bounds(meshes: meshes, matrices: skin.matrices, revision: revision)
            guard mesh.hasMorphTargets, morphByEntity[entity.id] != nil else { return }
            var largest: Float = 1
            for matrix in skin.matrices { largest = max(largest, matrix.x.xyz.length, matrix.y.xyz.length, matrix.z.xyz.length) }
            skinScale[entity.id] = largest
        }
        skinning.finishPackedWrites()

        // Query component columns once instead of resolving Entity.parent and optional components
        // separately for every mesh and every ancestor. No ancestor walk is needed if none are hidden.
        var hidden: Set<Entity.ID> = []
        visibility.batched().forEach { entity, value in if value == .hidden { hidden.insert(entity.id) } }
        var parents: [Entity.ID: Entity.ID] = [:]
        if !hidden.isEmpty {
            hierarchy.batched().forEach { entity, relationship in parents[entity.id] = relationship.parent }
        }
        var resolvedHidden: [Entity.ID: Bool] = [:]
        func isHidden(_ id: Entity.ID) -> Bool {
            if hidden.isEmpty { return false }
            if let value = resolvedHidden[id] { return value }
            // A provisional value also bounds malformed cyclic hierarchies.
            resolvedHidden[id] = false
            let value = hidden.contains(id) || parents[id].map(isHidden) == true
            resolvedHidden[id] = value
            return value
        }
        var forced: Set<Entity.ID> = []
        noCulling.batched().forEach { entity, _ in forced.insert(entity.id) }
        var materialOwnersChanged = false
        var meshCount = 0

        query.batched().forEach { entity, component, global in
            meshCount += 1
            if materialOwners[entity.id] != component.materialRevision { materialOwnersChanged = true }
            guard !isHidden(entity.id) else { return }
            let lod = lodByEntity[entity.id]
            let palette = skinning.buffer(for: entity.id)
            let forceVisible = forced.contains(entity.id)
            let matrix = global.matrix
            if let entry = entries[entity.id], entry.isStatic, palette == nil, morphByEntity[entity.id] == nil,
                entry.meshRevision == component.extractionRevision, entry.lodRevision == lod?.extractionRevision {
                let index = entry.index
                seen[index] = true
                // Do not write unchanged array elements: render nodes retain the last array snapshot.
                // A camera-only frame can consequently keep the entire source buffer without a COW copy.
                if sources.meshes[index].transform != matrix {
                    sources.meshes[index].previousTransform = sources.meshes[index].transform
                    sources.meshes[index].transform = matrix
                    sources.meshes[index].bounds = entry.localBounds.map { MeshVisibility3DMath.transformed($0, by: matrix) }
                } else if sources.meshes[index].previousTransform != matrix {
                    // Motion vectors settle on the frame after a mesh stops moving.
                    sources.meshes[index].previousTransform = matrix
                }
                if sources.meshes[index].forceVisible != forceVisible { sources.meshes[index].forceVisible = forceVisible }
                return
            }

            let mesh = component.mesh
            var bounds: AABB? = palette == nil ? mesh.bounds : posedBounds[entity.id]
            if palette == nil, let lod {
                for level in lod.alternatives {
                    bounds = bounds.map { AABB(min: min($0.min, level.bounds.min), max: max($0.max, level.bounds.max)) } ?? level.bounds
                }
            }
            var morphBuffers: [UInt64: any UniformBuffer] = [:]
            if mesh.hasMorphTargets, let weights = morphByEntity[entity.id] {
                var displacement: Float = 0
                for (key, buffer) in morphUniforms.write(weights: weights, mesh: mesh, for: entity.id, device: device) {
                    morphBuffers[Mesh3DRenderSource.morphKey(model: key.model, part: key.part)] = buffer
                    if let set = mesh.models[key.model].parts[key.part].morphTargets {
                        displacement = max(displacement, set.maximumDisplacement(for: weights))
                    }
                }
                if displacement > 0, let current = bounds {
                    let growth = Vector3.one * (displacement * (skinScale[entity.id] ?? 1))
                    bounds = AABB(min: current.min - growth, max: current.max + growth)
                }
            }
            let index = entries[entity.id]?.index ?? sources.meshes.count
            let previous = index < sources.meshes.count ? sources.meshes[index].transform : matrix
            let source = Mesh3DRenderSource(
                entity: entity.id, drawPass: drawPass, mesh: mesh, materials: component.materials,
                transform: matrix, bounds: bounds.map { MeshVisibility3DMath.transformed($0, by: matrix) },
                alternatives: morphBuffers.isEmpty && (palette == nil || lod?.skeletonCompatible == true && bounds != nil) ? lod?.alternatives ?? [] : [],
                thresholds: lod?.screenThresholds ?? [], hysteresis: lod?.hysteresis ?? 0.15,
                maximumDistance: lod?.maximumDistance, fadeDistance: lod?.fadeDistance ?? 4,
                forceVisible: forceVisible, castShadows: component.castShadows, receiveShadows: component.receiveShadows,
                skinningBuffer: palette, previousTransform: previous, morphBuffers: morphBuffers, skinningOffset: skinning.packedOffset(for: entity.id)
            )
            if index == sources.meshes.count {
                sources.meshes.append(source)
                seen.append(true)
            } else {
                sources.meshes[index] = source
                seen[index] = true
            }
            entries[entity.id] = Entry(index: index, meshRevision: component.extractionRevision, lodRevision: lod?.extractionRevision,
                                      localBounds: bounds, isStatic: palette == nil && morphByEntity[entity.id] == nil)
            geometryBuildCount &+= 1
        }
        // Each imported node shares its model's full material table. Scanning that table per mesh
        // repeated hundreds of thousands of casts on a static scene. Keep the union of live bindings,
        // including hidden meshes, and inspect each material only once per frame. Material objects
        // remain live: assigning a graph to an existing PBRMaterial still takes effect immediately.
        if materialOwnersChanged || materialOwners.count != meshCount {
            materialOwners.removeAll(keepingCapacity: true)
            uniqueMaterials.removeAll(keepingCapacity: true)
            query.batched().forEach { entity, component, _ in
                materialOwners[entity.id] = component.materialRevision
                for material in component.materials { uniqueMaterials[material.rid] = material }
            }
        }
        for material in uniqueMaterials.values { (material as? PBRMaterial)?.graphMaterial?.updateAutomaticTime(elapsed) }
        if let firstMissing = seen.firstIndex(of: false) {
            var destination = firstMissing
            for index in firstMissing..<seen.count {
                let id = sources.meshes[index].entity
                if seen[index] {
                    if destination != index {
                        sources.meshes[destination] = sources.meshes[index]
                        entries[id]?.index = destination
                    }
                    destination += 1
                } else {
                    entries.removeValue(forKey: id)
                }
            }
            sources.meshes.removeLast(seen.count - destination)
            seen.removeLast(seen.count - destination)
        }
        animatedBounds.finishFrame()
    }
}
