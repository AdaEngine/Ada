import AdaECS
@_spi(Internal) import AdaRender
import AdaUtils
import Math

/// The camera's compact draw buffers. DrawPass reads these only while the main 3D node encodes that view.
public struct Active3DInstanceBuffers: Resource {
    public var instances: BufferData<Flat3DInstanceData>?
    public var defaults: BufferData<Flat3DDefaultVertexData>?
    public var indirectArguments: (any Buffer)?
    public init() {}
}

/// Compact, frame-buffered draw lists per camera and per shadow cascade.
public struct VisibleMesh3DLists: Resource {
    private struct Key: Hashable {
        var view: Entity.ID
        var pass: Int
    }
    private struct Entry {
        var buffers = Opaque3DInstanceBuffers()
        var items: [Opaque3DRenderItem] = []
        var candidates: [GPUVisibilityCandidate] = []
        var count = Visibility3DCount()
        var records: [Record] = []
    }

    private struct SelectionKey: Hashable {
        var view: Entity.ID
        var entity: Entity.ID
    }
    private struct BatchKey: Hashable {
        var vertex: ObjectIdentifier
        var index: ObjectIdentifier
        var material: RID
        var skin: ObjectIdentifier?
        var cast: Bool
        var receive: Bool
    }

    private struct Record {
        var source: Int
        var mesh: Mesh
        var model: Int
        var part: Int
        var material: Material
        var fade: Float
        var key: BatchKey
        var rank: Int
        var sequence: Int
        var blended: Bool
    }

    private var entries: [Key: Entry] = [:]
    private var history: [SelectionKey: Int] = [:]
    public init() {}

    public mutating func retainViews(_ views: [Entity.ID]) {
        for key in entries.keys where !views.contains(key.view) { entries.removeValue(forKey: key) }
        for key in history.keys where !views.contains(key.view) { history.removeValue(forKey: key) }
    }

    public mutating func prepare(
        sources: [Mesh3DRenderSource],
        view: Entity.ID,
        pass: Int,
        viewMatrix: Transform3D,
        projection: Transform3D,
        cullingProjection: Transform3D,
        settings: MeshVisibilitySettings3D,
        device: RenderDevice,
        materials: inout PBR3DUniforms
    ) {
        let key = Key(view: view, pass: pass)
        var entry = entries.removeValue(forKey: key) ?? Entry()
        entry.items.removeAll(keepingCapacity: true)
        entry.buffers.beginFrame()
        entry.records.removeAll(keepingCapacity: true)
        entry.candidates.removeAll(keepingCapacity: true)
        entry.count = Visibility3DCount()
        let cameraPosition = viewMatrix.inverse.origin
        let frustum = MeshVisibilityFrustum3D(viewProjection: cullingProjection)
        var ranks: [BatchKey: Int] = [:]
        for (sourceIndex, source) in sources.enumerated() {
            if pass >= 0 && !source.castShadows { continue }
            entry.count.candidates += 1
            if settings.frustumCulling, !source.forceVisible, let bounds = source.bounds,
                !frustum.intersects(bounds) {
                entry.count.frustumRejected += 1
                continue
            }
            let center = source.bounds?.center ?? source.transform.origin
            let distance = (center - cameraPosition).length
            var fade: Float = 1
            if settings.distanceCulling, let maximum = source.maximumDistance, maximum.isFinite, maximum > 0 {
                if distance >= maximum {
                    entry.count.distanceRejected += 1
                    continue
                }
                let fadeDistance = finiteRenderValue(source.fadeDistance, fallback: 4, range: 0...maximum)
                if fadeDistance > 0 { fade = min(max((maximum - distance) / fadeDistance, 0), 1) }
            }
            let selectionKey = SelectionKey(view: view, entity: source.entity)
            var lod = 0
            if settings.lod, let bounds = source.bounds {
                lod = MeshVisibility3DMath.selectLOD(
                    size: MeshVisibility3DMath.projectedDiameter(bounds, view: viewMatrix, projection: projection),
                    thresholds: source.thresholds,
                    levels: source.alternatives.count + 1,
                    previous: history[selectionKey],
                    hysteresis: source.hysteresis
                )
                history[selectionKey] = lod
            }
            let mesh = lod == 0 ? source.mesh : source.alternatives[lod - 1]
            entry.count.visibleMeshes += 1
            entry.count.lodInstances[min(lod, 2)] += 1
            for model in source.mesh.models { for part in model.parts { entry.count.lod0Triangles += part.indexCount / 3 } }
            for (modelIndex, model) in mesh.models.enumerated() {
                for (partIndex, part) in model.parts.enumerated() {
                    guard source.materials.indices.contains(part.materialIndex) else { continue }
                    let material = source.materials[part.materialIndex]
                    if pass >= 0 && (material as? PBRMaterial)?.alphaMode == .blend { continue }
                    materials.write(material: material, descriptor: part.vertexDescriptor, device: device)
                    let batchKey = BatchKey(
                        vertex: ObjectIdentifier(part.vertexBuffer),
                        index: ObjectIdentifier(part.indexBuffer),
                        material: material.rid,
                        skin: source.skinningBuffer.map(ObjectIdentifier.init),
                        cast: source.castShadows,
                        receive: source.receiveShadows
                    )
                    let rank = ranks[batchKey] ?? ranks.count
                    ranks[batchKey] = rank
                    entry.records.append(
                        Record(
                            source: sourceIndex,
                            mesh: mesh,
                            model: modelIndex,
                            part: partIndex,
                            material: material,
                            fade: fade,
                            key: batchKey,
                            rank: rank,
                            sequence: entry.records.count,
                            blended: (material as? PBRMaterial)?.alphaMode == .blend
                        )
                    )
                    entry.count.triangles += part.indexCount / 3
                }
            }
        }
        // Keep opaque buckets adjacent before packing. BLEND remains one draw per instance and is
        // depth-sorted by Main3DRenderNode, preserving transparent compositing semantics.
        entry.records.sort {
            if $0.blended != $1.blended {
                return !$0.blended
            }
            if $0.rank != $1.rank {
                return $0.rank < $1.rank
            }
            return $0.sequence < $1.sequence
        }
        var previousKey: BatchKey?
        for record in entry.records {
            let source = sources[record.source]
            let part = record.mesh.models[record.model].parts[record.part]
            let instanceIndex = entry.buffers.append(makeInstance(source, material: record.material, descriptor: part.vertexDescriptor, fade: record.fade))
            if !record.blended, previousKey == record.key, let last = entry.items.indices.last {
                let lower = entry.items[last].batchRange?.lowerBound ?? instanceIndex
                entry.items[last].batchRange = lower..<(instanceIndex + 1)
            } else {
                entry.items.append(
                    Opaque3DRenderItem(
                        entity: source.entity,
                        drawPass: source.drawPass,
                        sortKey: 0,
                        modelIndex: record.model,
                        partIndex: record.part,
                        mesh: record.mesh,
                        material: record.material,
                        worldTransform: source.transform,
                        castShadows: source.castShadows,
                        receiveShadows: source.receiveShadows,
                        batchRange: instanceIndex..<(instanceIndex + 1),
                        skinningBuffer: source.skinningBuffer
                    )
                )
            }
            if pass < 0 && settings.gpuOcclusion, let item = entry.items.last, let range = item.batchRange {
                entry.candidates.append(
                    GPUVisibilityCandidate(
                        bounds: source.bounds,
                        draw: UInt32(entry.items.count - 1),
                        source: UInt32(instanceIndex),
                        destination: UInt32(range.lowerBound),
                        forceVisible: source.forceVisible || record.blended
                    )
                )
            }
            previousKey = record.blended ? nil : record.key
        }
        entry.buffers.write(to: device)
        entry.count.drawCalls = entry.items.count
        entries[key] = entry
    }

    public func gpuCandidates(view: Entity.ID, pass: Int) -> [GPUVisibilityCandidate] { entries[Key(view: view, pass: pass)]?.candidates ?? [] }

    public func items(view: Entity.ID, pass: Int) -> [Opaque3DRenderItem] { entries[Key(view: view, pass: pass)]?.items ?? [] }
    public func count(view: Entity.ID, pass: Int) -> Visibility3DCount { entries[Key(view: view, pass: pass)]?.count ?? Visibility3DCount() }
    public func buffers(view: Entity.ID, pass: Int) -> Active3DInstanceBuffers {
        var result = Active3DInstanceBuffers()
        if let entry = entries[Key(view: view, pass: pass)] {
            result.instances = entry.buffers.currentBuffer
            result.defaults = entry.buffers.defaultVertexBuffer
        }
        return result
    }

    private func makeInstance(_ source: Mesh3DRenderSource, material: Material, descriptor: VertexDescriptor, fade: Float) -> Flat3DInstanceData {
        let pbr = material as? PBRMaterial
        let atmosphere = material as? AtmosphereMaterial
        func hasUV(_ slot: Int) -> Bool {
            let set = pbr?.textureCoordinates.indices.contains(slot) == true ? pbr?.textureCoordinates[slot] ?? 0 : 0
            return descriptor.attributes.containsAttribute(by: set == 1 ? MeshDescriptor.textureCoordinates1.id.name : MeshDescriptor.textureCoordinates.id.name)
        }
        return Flat3DInstanceData(
            modelMatrix: source.transform,
            color: pbr?.baseColorFactor ?? .one,
            material: [pbr?.roughnessFactor ?? 1, pbr?.metallicFactor ?? 0, pbr?.emissiveStrength ?? 0, pbr?.emissiveLightThreshold ?? -1],
            textureFlags: [
                hasUV(0) && pbr?.baseColorTexture != nil ? 1 : 0,
                hasUV(1) && pbr?.metallicRoughnessTexture != nil ? 1 : 0,
                hasUV(2) && pbr?.normalTexture != nil ? 1 : 0,
                descriptor.attributes.containsAttribute(by: MeshDescriptor.tangents.id.name) ? 1 : 0,
            ],
            shadowFlags: [source.receiveShadows ? 1 : 0, atmosphere?.fresnelPower ?? 0, atmosphere?.atmosphereIntensity ?? 0, 1 - fade],
            previousModelMatrix: source.previousTransform
        )
    }
}
