import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Math

/// Retains camera-independent geometry. Component-owned revisions also catch edits between
/// two extractions in the same ECS tick, including edits through a component's mutable query.
struct Model3DExtractionCache: Resource {
    private struct Key: Hashable {
        let entity: Entity.ID
        let instanced: Bool
    }
    private struct Entry {
        var index: Int
        var meshRevision: RID
        var lodRevision: RID?
        var terrainMaskRevision: RID?
        var localBounds: AABB?
        var isStatic: Bool
        var settlesInstances = false
    }
    private var worldID: World.ID?
    private var entries: [Key: Entry] = [:]
    private var seen: [Bool] = []
    private var materialOwners: [Key: RID] = [:]
    private var uniqueMaterials: [RID: Material] = [:]
    private(set) var geometryBuildCount = 0

    mutating func extract(
        sourceWorldID: World.ID?,
        elapsed: Float,
        query: Query<Entity, Mesh3DComponent, GlobalTransform>,
        instanceQuery: Query<Entity, Mesh3DInstancesComponent, GlobalTransform>,
        lods: Query<Entity, MeshLOD3DComponent>,
        visibility: Query<Entity, Visibility>,
        noCulling: Query<Entity, NoFrustumCulling>,
        hierarchy: Query<Entity, RelationshipComponent>,
        skins: Query<Entity, SkinnedMesh3DComponent>,
        morphs: Query<Entity, MorphWeights3DComponent>,
        terrainMasks: Query<Entity, MeshTerrain3DSourceMask>,
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
        var masks: [Entity.ID: MeshTerrain3DSourceMask] = [:]
        terrainMasks.batched().forEach { entity, mask in masks[entity.id] = mask }
        var morphByEntity: [Entity.ID: [Float]] = [:]
        morphs.batched().forEach { entity, morph in morphByEntity[entity.id] = morph.weights }
        var posedBounds: [Entity.ID: AABB] = [:]
        var skinScale: [Entity.ID: Float] = [:]
        skins.batched().forEach { entity, skin in
            let revision = SkinningPoseRevision(id: skin.paletteID, generation: skin.poseGeneration)
            // Atmospheres keep the positive instance-Y channel for their own parameters.
            let isAtmosphere = entity.components[Mesh3DComponent.self]?.materials.contains { $0 is AtmosphereMaterial } == true
            if isAtmosphere {
                _ = skinning.write(skin.matrices, for: entity.id, device: device, revision: revision)
            } else {
                _ = skinning.writePacked(skin.matrices, for: entity.id, device: device, revision: revision)
            }
            guard let mesh = entity.components[Mesh3DComponent.self]?.mesh else {
                return
            }
            let lod = lodByEntity[entity.id]
            let meshes = lod?.skeletonCompatible == true ? [mesh] + (lod?.alternatives ?? []) : [mesh]
            posedBounds[entity.id] = animatedBounds.bounds(meshes: meshes, matrices: skin.matrices, revision: revision)
            guard mesh.hasMorphTargets, morphByEntity[entity.id] != nil else {
                return
            }
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
            if hidden.isEmpty {
                return false
            }
            if let value = resolvedHidden[id] {
                return value
            }
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
            let key = Key(entity: entity.id, instanced: false)
            meshCount += 1
            if materialOwners[key] != component.materialRevision { materialOwnersChanged = true }
            guard !isHidden(entity.id) else {
                return
            }
            let mask = masks[entity.id]
            if let mask, MeshTerrainDrawMasking.fullyMasked(component.mesh, by: mask) { return }
            let lod = lodByEntity[entity.id]
            let palette = skinning.buffer(for: entity.id)
            let forceVisible = forced.contains(entity.id)
            let matrix = global.matrix
            if let entry = entries[key], entry.isStatic, palette == nil, morphByEntity[entity.id] == nil,
                entry.meshRevision == component.extractionRevision, entry.lodRevision == lod?.extractionRevision,
                entry.terrainMaskRevision == mask?.revision {
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

            let mesh = mask.map { MeshTerrainDrawMasking.applying($0, to: component.mesh) } ?? component.mesh
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
            let index = entries[key]?.index ?? sources.meshes.count
            let previous = index < sources.meshes.count ? sources.meshes[index].transform : matrix
            let source = Mesh3DRenderSource(
                entity: entity.id,
                drawPass: drawPass,
                mesh: mesh,
                materials: component.materials,
                transform: matrix,
                bounds: bounds.map { MeshVisibility3DMath.transformed($0, by: matrix) },
                alternatives: mask == nil && morphBuffers.isEmpty && (palette == nil || lod?.skeletonCompatible == true && bounds != nil) ? lod?.alternatives ?? [] : [],
                thresholds: lod?.screenThresholds ?? [],
                hysteresis: lod?.hysteresis ?? 0.15,
                maximumDistance: lod?.maximumDistance,
                fadeDistance: lod?.fadeDistance ?? 4,
                forceVisible: forceVisible,
                castShadows: component.castShadows,
                receiveShadows: component.receiveShadows,
                skinningBuffer: palette,
                previousTransform: previous,
                morphBuffers: morphBuffers,
                skinningOffset: skinning.packedOffset(for: entity.id)
            )
            if index == sources.meshes.count {
                sources.meshes.append(source)
                seen.append(true)
            } else {
                sources.meshes[index] = source
                seen[index] = true
            }
            entries[key] = Entry(
                index: index,
                meshRevision: component.extractionRevision,
                lodRevision: lod?.extractionRevision,
                terrainMaskRevision: mask?.revision,
                localBounds: bounds,
                isStatic: palette == nil && morphByEntity[entity.id] == nil
            )
            geometryBuildCount &+= 1
        }
        instanceQuery.batched().forEach { entity, component, global in
            let key = Key(entity: entity.id, instanced: true)
            meshCount += 1
            if materialOwners[key] != component.extractionRevision { materialOwnersChanged = true }
            guard !isHidden(entity.id), !component.instances.isEmpty else {
                return
            }
            let matrix = global.matrix
            let lod = lodByEntity[entity.id]
            let forced = forced.contains(entity.id)
            if let entry = entries[key], entry.meshRevision == component.extractionRevision, entry.lodRevision == lod?.extractionRevision {
                let index = entry.index
                seen[index] = true
                if sources.meshes[index].transform != matrix {
                    sources.meshes[index].previousTransform = sources.meshes[index].transform
                    sources.meshes[index].transform = matrix
                    sources.meshes[index].bounds = entry.localBounds.map { MeshVisibility3DMath.transformed($0, by: matrix) }
                } else if sources.meshes[index].previousTransform != matrix {
                    sources.meshes[index].previousTransform = matrix
                }
                if entry.settlesInstances {
                    sources.meshes[index].previousInstances = sources.meshes[index].instances
                    entries[key]?.settlesInstances = false
                }
                if sources.meshes[index].forceVisible != forced { sources.meshes[index].forceVisible = forced }
                return
            }
            var prototypeBounds = component.mesh.bounds
            for mesh in lod?.alternatives ?? [] { prototypeBounds = AABB(min: min(prototypeBounds.min, mesh.bounds.min), max: max(prototypeBounds.max, mesh.bounds.max)) }
            var localBounds: AABB?
            for instance in component.instances {
                let bounds = MeshVisibility3DMath.transformed(prototypeBounds, by: instance.transform)
                if let current = localBounds { localBounds = AABB(min: min(current.min, bounds.min), max: max(current.max, bounds.max)) } else { localBounds = bounds }
            }
            let index = entries[key]?.index ?? sources.meshes.count
            let previousTransform = index < sources.meshes.count ? sources.meshes[index].transform : matrix
            let oldInstances = index < sources.meshes.count ? sources.meshes[index].instances : nil
            var previousByID: [UInt64: Transform3D] = [:]
            for instance in oldInstances ?? [] { previousByID[instance.id] = instance.transform }
            let previousInstances = component.instances.map { instance -> Mesh3DInstance in
                var previous = instance
                previous.transform = previousByID[instance.id] ?? instance.transform
                return previous
            }
            var source = Mesh3DRenderSource(
                entity: entity.id,
                drawPass: drawPass,
                mesh: component.mesh,
                materials: component.materials,
                transform: matrix,
                bounds: localBounds.map { MeshVisibility3DMath.transformed($0, by: matrix) },
                alternatives: lod?.alternatives ?? [],
                thresholds: lod?.screenThresholds ?? [],
                hysteresis: lod?.hysteresis ?? 0.15,
                maximumDistance: lod?.maximumDistance,
                fadeDistance: lod?.fadeDistance ?? 4,
                forceVisible: forced,
                castShadows: component.castShadows,
                receiveShadows: component.receiveShadows,
                previousTransform: previousTransform
            )
            source.instances = component.instances
            source.previousInstances = previousInstances
            if index == sources.meshes.count { sources.meshes.append(source); seen.append(true) } else { sources.meshes[index] = source; seen[index] = true }
            entries[key] = Entry(
                index: index,
                meshRevision: component.extractionRevision,
                lodRevision: lod?.extractionRevision,
                localBounds: localBounds,
                isStatic: true,
                settlesInstances: oldInstances != nil
            )
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
                materialOwners[Key(entity: entity.id, instanced: false)] = component.materialRevision
                for material in component.materials { uniqueMaterials[material.rid] = material }
            }
        }
        if materialOwnersChanged || materialOwners.count != meshCount {
            instanceQuery.batched().forEach { entity, component, _ in
                materialOwners[Key(entity: entity.id, instanced: true)] = component.extractionRevision
                for material in component.materials { uniqueMaterials[material.rid] = material }
            }
        }
        for material in uniqueMaterials.values { (material as? PBRMaterial)?.graphMaterial?.updateAutomaticTime(elapsed) }
        if let firstMissing = seen.firstIndex(of: false) {
            var destination = firstMissing
            for index in firstMissing..<seen.count {
                let id = Key(entity: sources.meshes[index].entity, instanced: sources.meshes[index].instances != nil)
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
