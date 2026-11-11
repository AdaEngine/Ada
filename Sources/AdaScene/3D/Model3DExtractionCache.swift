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
    private static let observedComponents: Set<ComponentId> = [
        GlobalTransform.identifier, Mesh3DComponent.identifier, Mesh3DInstancesComponent.identifier,
        MeshLOD3DComponent.identifier, Visibility.identifier, NoFrustumCulling.identifier,
        RelationshipComponent.identifier, SkinnedMesh3DComponent.identifier, MorphWeights3DComponent.identifier,
        MeshTerrain3DSourceMask.identifier, PathTracingGeometry3D.identifier
    ]
    private var cursor: UInt64?
    private struct MaterialSlot {
        let source: Int
        let slot: Int
    }
    private var materialRevisions: [RID: UInt64] = [:]
    private var materialSlots: [RID: [MaterialSlot]] = [:]
    private var canApplyTransformChanges = false
    private var usesMaterialSnapshots = false
    private var settlingTransforms: Set<Entity.ID> = []
    /// Every extracted mesh, indexed by ``Entry/index``; ``ExtractedMesh3DSources`` publishes views of it.
    private var storage: [Mesh3DRenderSource] = []
    private(set) var geometryBuildCount = 0
    private(set) var sourceVisitCount = 0

    mutating func extract(
        sourceWorld: World?,
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
        pathTracingRoles: Query<Entity, PathTracingGeometry3D>? = nil,
        sources: inout ExtractedMesh3DSources,
        animatedBounds: inout AnimatedBounds3D,
        skinning: inout Skinning3DUniforms,
        morphUniforms: inout Morph3DUniforms,
        materials: inout PBR3DUniforms,
        device: RenderDevice,
        drawPass: Model3DDrawPass,
        snapshotsMaterials: Bool = false
    ) {
        // Drop the published share first, so in-place updates of `storage` do not copy the whole array.
        sources.meshes = []
        sources.pathTracingProxies = []
        sources.transformChanges = nil
        if worldID != sourceWorld?.id {
            entries.removeAll(keepingCapacity: true)
            storage.removeAll(keepingCapacity: true)
            seen.removeAll(keepingCapacity: true)
            materialOwners.removeAll(keepingCapacity: true)
            uniqueMaterials.removeAll(keepingCapacity: true)
            worldID = sourceWorld?.id
            cursor = nil
            canApplyTransformChanges = false
        }
        var changes: [ComponentChangeJournal.Change]?
        if let sourceWorld {
            if let cursor {
                let batch = sourceWorld.componentChanges.read(after: cursor)
                changes = batch.changes
                self.cursor = batch.cursor
            } else {
                cursor = sourceWorld.componentChanges.observe(Self.observedComponents)
            }
        }
        animatedBounds.beginFrame()
        skinning.beginFrame(device: device)
        morphUniforms.beginFrame()
        materials.beginFrame()
        if let sourceWorld, let changes, canApplyTransformChanges,
           usesMaterialSnapshots == snapshotsMaterials,
           let update = applyTransformChanges(changes, from: sourceWorld) {
            sources.meshes = storage
            if !update.changedMaterials { sources.transformChanges = update.indices }
            skinning.finishPackedWrites()
            animatedBounds.finishFrame()
            return
        }
        for index in seen.indices { seen[index] = false }

        var lodByEntity: [Entity.ID: MeshLOD3DComponent] = [:]
        lods.batched().forEach { entity, lod in lodByEntity[entity.id] = lod }
        var masks: [Entity.ID: MeshTerrain3DSourceMask] = [:]
        terrainMasks.batched().forEach { entity, mask in masks[entity.id] = mask }
        var morphByEntity: [Entity.ID: [Float]] = [:]
        morphs.batched().forEach { entity, morph in morphByEntity[entity.id] = morph.weights }
        var posedBounds: [Entity.ID: AABB] = [:]
        var skinScale: [Entity.ID: Float] = [:]
        var hasSkins = false
        skins.batched().forEach { entity, skin in
            hasSkins = true
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
        var roleComponents: [Entity.ID: PathTracingGeometry3D] = [:]
        pathTracingRoles?.batched().forEach { entity, role in roleComponents[entity.id] = role }
        if !roleComponents.isEmpty, parents.isEmpty {
            hierarchy.batched().forEach { entity, relationship in parents[entity.id] = relationship.parent }
        }
        var resolvedRoles: [Entity.ID: PathTracingGeometry3D?] = [:]
        func role(_ id: Entity.ID) -> PathTracingGeometry3D? {
            if roleComponents.isEmpty { return nil }
            if let value = resolvedRoles[id] { return value }
            // A provisional value also bounds malformed cyclic hierarchies.
            resolvedRoles[id] = .some(nil)
            let value = roleComponents[id] ?? parents[id].flatMap(role)
            resolvedRoles[id] = .some(value)
            return value
        }
        var roles = false
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
            let pathTracing = role(entity.id)
            if pathTracing != nil { roles = true }
            if let entry = entries[key], entry.isStatic, palette == nil, morphByEntity[entity.id] == nil,
                storage[entry.index].pathTracing == pathTracing,
                entry.meshRevision == component.extractionRevision, entry.lodRevision == lod?.extractionRevision,
                entry.terrainMaskRevision == mask?.revision {
                let index = entry.index
                seen[index] = true
                // Do not write unchanged array elements: render nodes retain the last array snapshot.
                // A camera-only frame can consequently keep the entire source buffer without a COW copy.
                if storage[index].transform != matrix {
                    storage[index].previousTransform = storage[index].transform
                    storage[index].transform = matrix
                    storage[index].bounds = entry.localBounds.map { MeshVisibility3DMath.transformed($0, by: matrix) }
                } else if storage[index].previousTransform != matrix {
                    // Motion vectors settle on the frame after a mesh stops moving.
                    storage[index].previousTransform = matrix
                }
                if storage[index].forceVisible != forceVisible { storage[index].forceVisible = forceVisible }
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
            let index = entries[key]?.index ?? storage.count
            let previous = index < storage.count ? storage[index].transform : matrix
            var source = Mesh3DRenderSource(
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
            source.pathTracing = pathTracing
            if index == storage.count {
                storage.append(source)
                seen.append(true)
            } else {
                storage[index] = source
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
            let pathTracing = role(entity.id)
            if pathTracing != nil { roles = true }
            if let entry = entries[key], entry.meshRevision == component.extractionRevision, entry.lodRevision == lod?.extractionRevision,
                storage[entry.index].pathTracing == pathTracing {
                let index = entry.index
                seen[index] = true
                if storage[index].transform != matrix {
                    storage[index].previousTransform = storage[index].transform
                    storage[index].transform = matrix
                    storage[index].bounds = entry.localBounds.map { MeshVisibility3DMath.transformed($0, by: matrix) }
                } else if storage[index].previousTransform != matrix {
                    storage[index].previousTransform = matrix
                }
                if entry.settlesInstances {
                    storage[index].previousInstances = storage[index].instances
                    entries[key]?.settlesInstances = false
                }
                if storage[index].forceVisible != forced { storage[index].forceVisible = forced }
                return
            }
            var prototypeBounds = component.mesh.bounds
            for mesh in lod?.alternatives ?? [] { prototypeBounds = AABB(min: min(prototypeBounds.min, mesh.bounds.min), max: max(prototypeBounds.max, mesh.bounds.max)) }
            var localBounds: AABB?
            for instance in component.instances {
                let bounds = MeshVisibility3DMath.transformed(prototypeBounds, by: instance.transform)
                if let current = localBounds { localBounds = AABB(min: min(current.min, bounds.min), max: max(current.max, bounds.max)) } else { localBounds = bounds }
            }
            let index = entries[key]?.index ?? storage.count
            let previousTransform = index < storage.count ? storage[index].transform : matrix
            let oldInstances = index < storage.count ? storage[index].instances : nil
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
            source.pathTracing = pathTracing
            if index == storage.count { storage.append(source); seen.append(true) } else { storage[index] = source; seen[index] = true }
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
        sourceVisitCount &+= meshCount
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
                let id = Key(entity: storage[index].entity, instanced: storage[index].instances != nil)
                if seen[index] {
                    if destination != index {
                        storage[destination] = storage[index]
                        entries[id]?.index = destination
                    }
                    destination += 1
                } else {
                    entries.removeValue(forKey: id)
                }
            }
            storage.removeLast(seen.count - destination)
            seen.removeLast(seen.count - destination)
        }
        if snapshotsMaterials { Self.useRenderSnapshots(in: &storage) }
        usesMaterialSnapshots = snapshotsMaterials
        settlingTransforms = Set(storage.lazy.filter { $0.transform != $0.previousTransform }.map(\.entity))
        materialRevisions.removeAll(keepingCapacity: true)
        materialSlots.removeAll(keepingCapacity: true)
        for (id, material) in uniqueMaterials {
            if let pbr = material as? PBRMaterial, type(of: pbr) == PBRMaterial.self, pbr.graphMaterial == nil {
                materialRevisions[id] = pbr.stateRevision
            }
        }
        canApplyTransformChanges = masks.isEmpty && !hasSkins && morphByEntity.isEmpty
            && hidden.isEmpty && !roles && materialRevisions.count == uniqueMaterials.count
            && !entries.values.contains(where: \.settlesInstances)
        if canApplyTransformChanges, snapshotsMaterials {
            for (index, source) in storage.enumerated() {
                for (slot, material) in source.materials.enumerated() {
                    let id = (material as? PBRMaterial)?.snapshotSource?.rid ?? material.rid
                    materialSlots[id, default: []].append(MaterialSlot(source: index, slot: slot))
                }
            }
        }
        publish(into: &sources, roles: roles)
        animatedBounds.finishFrame()
    }

    /// Ordinary retained geometry uses the stream to read only changed transforms.
    /// The full extractor still owns structural changes and specialized geometry.
    private mutating func applyTransformChanges(
        _ changes: [ComponentChangeJournal.Change], from world: World
    ) -> (indices: [Int], changedMaterials: Bool)? {
        guard changes.allSatisfy({ $0.component == GlobalTransform.identifier }) else { return nil }
        var editedMaterials: [(RID, PBRMaterial)] = []
        for (id, material) in uniqueMaterials {
            guard let pbr = material as? PBRMaterial, pbr.graphMaterial == nil else { return nil }
            if materialRevisions[id] != pbr.stateRevision { editedMaterials.append((id, pbr)) }
        }
        let entities = settlingTransforms.union(changes.lazy.map(\.entity))
        var updates: [(Key, Transform3D)] = []
        updates.reserveCapacity(entities.count)
        for entity in entities {
            let key = Key(entity: entity, instanced: false)
            if entries[Key(entity: entity, instanced: true)] != nil { return nil }
            guard entries[key] != nil else { continue }
            guard let global = world.get(GlobalTransform.self, from: entity) else { return nil }
            updates.append((key, global.matrix))
        }
        sourceVisitCount &+= updates.count
        settlingTransforms.removeAll(keepingCapacity: true)
        var indices: [Int] = []
        indices.reserveCapacity(updates.count)
        for (key, matrix) in updates {
            guard let entry = entries[key] else { continue }
            let index = entry.index
            if storage[index].transform != matrix {
                storage[index].previousTransform = storage[index].transform
                storage[index].transform = matrix
                storage[index].bounds = entry.localBounds.map { MeshVisibility3DMath.transformed($0, by: matrix) }
                settlingTransforms.insert(key.entity)
                indices.append(index)
            } else if storage[index].previousTransform != matrix {
                storage[index].previousTransform = matrix
                indices.append(index)
            }
        }
        for (id, material) in editedMaterials {
            materialRevisions[id] = material.stateRevision
            if usesMaterialSnapshots {
                let snapshot = material.renderSnapshot()
                for entry in materialSlots[id] ?? [] {
                    storage[entry.source].materials[entry.slot] = snapshot
                }
            }
        }
        return (indices.sorted(), !editedMaterials.isEmpty)
    }

    /// Publishes the raster meshes and, when any mesh is ``PathTracingGeometry3D/pathTracingOnly``, the tracer's proxies.
    /// Without roles the published array shares `storage` without copying.
    private func publish(into sources: inout ExtractedMesh3DSources, roles: Bool) {
        guard roles, storage.contains(where: { $0.pathTracing == PathTracingGeometry3D.pathTracingOnly }) else {
            sources.meshes = storage
            sources.pathTracingProxies = []
            return
        }
        sources.meshes = storage.filter { $0.pathTracing != PathTracingGeometry3D.pathTracingOnly }
        sources.pathTracingProxies = storage.filter { $0.pathTracing == PathTracingGeometry3D.pathTracingOnly }
    }

    static func useRenderSnapshots(in sources: inout ExtractedMesh3DSources) {
        useRenderSnapshots(in: &sources.meshes)
        useRenderSnapshots(in: &sources.pathTracingProxies)
    }

    /// Replaces live materials with their render snapshots (see `PBRMaterial.renderSnapshot()`), so a pipelined
    /// render world never reads an object that gameplay edits for the next frame. Sources persist between
    /// frames and already hold snapshots, which lead back to their live material.
    static func useRenderSnapshots(in meshes: inout [Mesh3DRenderSource]) {
        var resolved: [ObjectIdentifier: Material] = [:]
        for index in meshes.indices {
            let current = meshes[index].materials
            var replacement: [Material]?
            for (slot, material) in current.enumerated() {
                let snapshot: Material
                if let known = resolved[ObjectIdentifier(material)] {
                    snapshot = known
                } else {
                    let pbr = material as? PBRMaterial
                    snapshot = (pbr?.snapshotSource ?? pbr)?.renderSnapshot() ?? material
                    resolved[ObjectIdentifier(material)] = snapshot
                }
                if snapshot !== material {
                    if replacement == nil { replacement = current }
                    replacement?[slot] = snapshot
                }
            }
            if let replacement { meshes[index].materials = replacement }
        }
    }

}
