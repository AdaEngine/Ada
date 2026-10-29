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
/// A cheap rolling hash used to tell whether a shadow face would draw the same thing as last frame.
struct FrameDigest3D: Sendable {
    private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325

    mutating func combine(_ word: UInt64) {
        value = (value ^ word) &* 0x0000_0100_0000_01b3
        value ^= value >> 29
    }

    mutating func combine(_ float: Float) { combine(UInt64(float.bitPattern)) }

    mutating func combine(_ vector: Vector4) {
        combine(vector.x)
        combine(vector.y)
        combine(vector.z)
        combine(vector.w)
    }

    mutating func combine(_ matrix: Transform3D) {
        combine(matrix.x)
        combine(matrix.y)
        combine(matrix.z)
        combine(matrix.w)
    }
}

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
        var order: [Int32] = []
        var digest = FrameDigest3D()
        var isDynamic = false
    }

    private struct SelectionKey: Hashable {
        var view: Entity.ID
        var entity: Entity.ID
    }
    private struct BatchKey: Hashable {
        var vertex: ObjectIdentifier
        var index: ObjectIdentifier
        var indexCount: Int
        var material: MaterialKey
        var descriptor: Int32
        var skin: ObjectIdentifier?
        var morph: ObjectIdentifier?
        var cast: Bool
        var receive: Bool
    }

    private enum MaterialKey: Hashable {
        case identity(RID)
        // Shadow shaders consume the shared parameter buffer and base texture;
        // separate material objects with identical bindings can share a draw.
        case shadow(ObjectIdentifier, ObjectIdentifier?)
    }

    /// What a part contributes to a batch that does not depend on which source it came from. Built once per
    /// distinct batch per call instead of once per visible part.
    private struct BatchTemplate {
        var color: Vector4
        var material: Vector4
        var textureFlags: Vector4
        var shadowFlags: Vector4
        var blended: Bool
        /// Batch order, assigned when the first record of this batch is appended.
        var rank: Int
        /// Hash of the batch key, which names the mesh part, material parameters and skin of every instance in it.
        var batchHash: UInt64 = 0
    }

    /// A visible part, kept free of references so building, ordering and reading thousands of them costs no
    /// reference counting.
    private struct Record {
        var source: Int32
        var lod: Int32
        var model: Int32
        var part: Int32
        var material: Int32
        var template: Int32
        var fade: Float
    }

    private var entries: [Key: Entry] = [:]
    /// Passes prepared since creation, for tests that check which lists a frame rebuilt.
    private(set) var preparedPassCount = 0
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
        preparedPassCount &+= 1
        let key = Key(view: view, pass: pass)
        var entry = entries.removeValue(forKey: key) ?? Entry()
        entry.items.removeAll(keepingCapacity: true)
        entry.buffers.beginFrame()
        entry.records.removeAll(keepingCapacity: true)
        entry.order.removeAll(keepingCapacity: true)
        entry.candidates.removeAll(keepingCapacity: true)
        entry.count = Visibility3DCount()
        entry.digest = FrameDigest3D()
        entry.isDynamic = false
        let cameraPosition = viewMatrix.inverse.origin
        let frustum = MeshVisibilityFrustum3D(viewProjection: cullingProjection)
        let isShadowPass = pass >= 0
        var templateIndex: [BatchKey: Int32] = [:]
        var templates: [BatchTemplate] = []
        var rankCount = 0
        var descriptors: [VertexDescriptor] = []
        // The loops read fields straight from the array instead of binding each source: a source is a large value
        // with several references, and copying it for every pass and every mesh dominated this function.
        for sourceIndex in sources.indices {
            if isShadowPass && !sources[sourceIndex].castShadows { continue }
            entry.count.candidates += 1
            if settings.frustumCulling, !sources[sourceIndex].forceVisible, let bounds = sources[sourceIndex].bounds,
                !frustum.intersects(bounds) {
                entry.count.frustumRejected += 1
                continue
            }
            var fade: Float = 1
            if settings.distanceCulling, let maximum = sources[sourceIndex].maximumDistance, maximum.isFinite, maximum > 0 {
                let center = sources[sourceIndex].bounds?.center ?? sources[sourceIndex].transform.origin
                let distance = (center - cameraPosition).length
                if distance >= maximum {
                    entry.count.distanceRejected += 1
                    continue
                }
                let fadeDistance = finiteRenderValue(sources[sourceIndex].fadeDistance, fallback: 4, range: 0...maximum)
                if fadeDistance > 0 { fade = min(max((maximum - distance) / fadeDistance, 0), 1) }
            }
            var lod = 0
            // A mesh with no alternatives is always level zero; skipping the selection also keeps it out of the
            // hysteresis history, which only matters for meshes that can change level.
            if settings.lod, !sources[sourceIndex].alternatives.isEmpty, let bounds = sources[sourceIndex].bounds {
                let selectionKey = SelectionKey(view: view, entity: sources[sourceIndex].entity)
                lod = MeshVisibility3DMath.selectLOD(
                    size: MeshVisibility3DMath.projectedDiameter(bounds, view: viewMatrix, projection: projection),
                    thresholds: sources[sourceIndex].thresholds,
                    levels: sources[sourceIndex].alternatives.count + 1,
                    previous: history[selectionKey],
                    hysteresis: sources[sourceIndex].hysteresis
                )
                history[selectionKey] = lod
            }
            entry.count.visibleMeshes += 1
            entry.count.lodInstances[min(lod, 2)] += 1
            let sourceMesh = sources[sourceIndex].mesh
            for modelIndex in sourceMesh.models.indices {
                for partIndex in sourceMesh.models[modelIndex].parts.indices {
                    entry.count.lod0Triangles += sourceMesh.models[modelIndex].parts[partIndex].indexCount / 3
                }
            }
            let mesh = lod == 0 ? sourceMesh : sources[sourceIndex].alternatives[lod - 1]
            for modelIndex in mesh.models.indices {
                let parts = mesh.models[modelIndex].parts
                for partIndex in parts.indices {
                    let materialIndex = parts[partIndex].materialIndex
                    guard sources[sourceIndex].materials.indices.contains(materialIndex) else { continue }
                    let material = sources[sourceIndex].materials[materialIndex]
                    let pbr = material as? PBRMaterial
                    if isShadowPass && pbr?.effectiveAlphaMode == .blend { continue }
                    // Batches never mix vertex layouts: the descriptor is interned per call so the key stays cheap.
                    let descriptor = parts[partIndex].vertexDescriptor
                    var descriptorID = -1
                    if let last = descriptors.indices.last, descriptors[last] == descriptor {
                        descriptorID = last
                    } else if let found = descriptors.firstIndex(of: descriptor) {
                        descriptorID = found
                    } else {
                        descriptorID = descriptors.count
                        descriptors.append(descriptor)
                    }
                    let materialKey: MaterialKey
                    if isShadowPass {
                        // The parameter buffer must exist before it can be part of the key.
                        materials.write(material: material, descriptor: descriptor, device: device)
                        if let pbr, pbr.graphMaterial == nil || pbr.effectiveAlphaMode != .mask, let buffer = materials.buffer(for: material) {
                            materialKey = .shadow(ObjectIdentifier(buffer), pbr.baseColorTexture.map(ObjectIdentifier.init))
                        } else {
                            materialKey = .identity(material.rid)
                        }
                    } else {
                        materialKey = .identity(material.rid)
                    }
                    let batchKey = BatchKey(
                        vertex: ObjectIdentifier(parts[partIndex].vertexBuffer),
                        index: ObjectIdentifier(parts[partIndex].indexBuffer),
                        indexCount: parts[partIndex].indexCount,
                        material: materialKey,
                        descriptor: Int32(descriptorID),
                        skin: sources[sourceIndex].skinningBuffer.map(ObjectIdentifier.init),
                        morph: sources[sourceIndex].morphBuffers[Mesh3DRenderSource.morphKey(model: modelIndex, part: partIndex)].map(ObjectIdentifier.init),
                        cast: sources[sourceIndex].castShadows,
                        receive: sources[sourceIndex].receiveShadows
                    )
                    let template: Int32
                    if let existing = templateIndex[batchKey] {
                        template = existing
                    } else {
                        // Written once per batch: the uniform depends only on the material and vertex layout.
                        if !isShadowPass { materials.write(material: material, descriptor: descriptor, device: device) }
                        template = Int32(templates.count)
                        templateIndex[batchKey] = template
                        let templateHash = UInt64(bitPattern: Int64(batchKey.hashValue))
                        templates.append(Self.makeTemplate(
                            material: material,
                            descriptor: descriptor,
                            receivesShadows: sources[sourceIndex].receiveShadows,
                            blended: pbr?.effectiveAlphaMode == .blend,
                            shadowOnly: isShadowPass
                        ))
                        templates[Int(template)].batchHash = templateHash
                    }
                    if templates[Int(template)].rank < 0 {
                        templates[Int(template)].rank = rankCount
                        rankCount += 1
                    }
                    entry.records.append(Record(
                        source: Int32(sourceIndex),
                        lod: Int32(lod),
                        model: Int32(modelIndex),
                        part: Int32(partIndex),
                        material: Int32(materialIndex),
                        template: template,
                        fade: fade
                    ))
                    entry.count.triangles += parts[partIndex].indexCount / 3
                }
            }
        }
        // Keep opaque buckets adjacent before packing: opaque batches first, each in the order it was first seen and
        // each keeping its records in submission order. BLEND remains one draw per instance and is depth-sorted by
        // Main3DRenderNode, preserving transparent compositing semantics. A counting placement does this in linear time.
        let bucketCount = rankCount * 2
        var offsets = [Int32](repeating: 0, count: bucketCount + 1)
        for record in entry.records {
            let template = templates[Int(record.template)]
            offsets[(template.blended ? rankCount : 0) + template.rank + 1] += 1
        }
        for bucket in 0..<bucketCount { offsets[bucket + 1] += offsets[bucket] }
        entry.order = [Int32](repeating: 0, count: entry.records.count)
        for (recordIndex, record) in entry.records.enumerated() {
            let template = templates[Int(record.template)]
            let bucket = (template.blended ? rankCount : 0) + template.rank
            entry.order[Int(offsets[bucket])] = Int32(recordIndex)
            offsets[bucket] += 1
        }
        var previousTemplate: Int32 = -1
        for orderIndex in entry.order {
            let record = entry.records[Int(orderIndex)]
            let sourceIndex = Int(record.source)
            let template = templates[Int(record.template)]
            var shadowFlags = template.shadowFlags
            shadowFlags.w = 1 - record.fade
            // Positive Y belongs to atmospheres. Negative values carry an exact
            // joint base without exceeding WebGPU's 16 vertex-attribute limit.
            if sources[sourceIndex].skinningOffset > 0 { shadowFlags.y = -Float(sources[sourceIndex].skinningOffset) }
            if isShadowPass {
                // A skinned pose changes without any CPU-visible identity change, so such a face is never reusable.
                if sources[sourceIndex].skinningBuffer != nil || !sources[sourceIndex].morphBuffers.isEmpty { entry.isDynamic = true }
                entry.digest.combine(template.batchHash)
                entry.digest.combine(sources[sourceIndex].transform)
                entry.digest.combine((sources[sourceIndex].materials[Int(record.material)] as? PBRMaterial)?.baseColorFactor ?? .one)
                if let pbr = sources[sourceIndex].materials[Int(record.material)] as? PBRMaterial,
                    pbr.effectiveAlphaMode == .mask, let graph = pbr.graphMaterial {
                    entry.digest.combine(graph.valueRevision)
                }
                entry.digest.combine(shadowFlags.w)
            }
            let instanceIndex = entry.buffers.append(Flat3DInstanceData(
                modelMatrix: sources[sourceIndex].transform,
                // Shadow batches can mix materials that only differ in colour, so that comes from the record itself.
                color: isShadowPass ? (sources[sourceIndex].materials[Int(record.material)] as? PBRMaterial)?.baseColorFactor ?? .one : template.color,
                material: template.material,
                textureFlags: template.textureFlags,
                shadowFlags: shadowFlags,
                previousModelMatrix: isShadowPass ? nil : sources[sourceIndex].previousTransform
            ))
            if !template.blended, previousTemplate == record.template, let last = entry.items.indices.last {
                let lower = entry.items[last].batchRange?.lowerBound ?? instanceIndex
                entry.items[last].batchRange = lower..<(instanceIndex + 1)
            } else {
                let mesh = record.lod == 0 ? sources[sourceIndex].mesh : sources[sourceIndex].alternatives[Int(record.lod) - 1]
                entry.items.append(
                    Opaque3DRenderItem(
                        entity: sources[sourceIndex].entity,
                        drawPass: sources[sourceIndex].drawPass,
                        sortKey: 0,
                        modelIndex: Int(record.model),
                        partIndex: Int(record.part),
                        mesh: mesh,
                        material: sources[sourceIndex].materials[Int(record.material)],
                        worldTransform: sources[sourceIndex].transform,
                        castShadows: sources[sourceIndex].castShadows,
                        receiveShadows: sources[sourceIndex].receiveShadows,
                        batchRange: instanceIndex..<(instanceIndex + 1),
                        skinningBuffer: sources[sourceIndex].skinningBuffer,
                        morphBuffer: sources[sourceIndex].morphBuffers[Mesh3DRenderSource.morphKey(model: Int(record.model), part: Int(record.part))]
                    )
                )
            }
            if pass < 0 && settings.gpuOcclusion, let item = entry.items.last, let range = item.batchRange {
                entry.candidates.append(
                    GPUVisibilityCandidate(
                        bounds: sources[sourceIndex].bounds,
                        draw: UInt32(entry.items.count - 1),
                        source: UInt32(instanceIndex),
                        destination: UInt32(range.lowerBound),
                        forceVisible: sources[sourceIndex].forceVisible || template.blended
                    )
                )
            }
            previousTemplate = template.blended ? -1 : record.template
        }
        entry.buffers.write(to: device)
        entry.count.drawCalls = entry.items.count
        entries[key] = entry
    }

    /// Fingerprint of everything a shadow pass would draw (batches, transforms, alpha inputs), or `nil` when the pass
    /// contains skinned meshes whose pose changes without any visible change here. Equal fingerprints mean an
    /// identical face. Meshes edited in place keep their buffer identity and are not noticed.
    func shadowDigest(view: Entity.ID, pass: Int) -> UInt64? {
        guard let entry = entries[Key(view: view, pass: pass)], !entry.isDynamic else {
            return nil
        }
        var digest = entry.digest
        digest.combine(UInt64(entry.items.count))
        return digest.value
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

    private static func makeTemplate(material: Material, descriptor: VertexDescriptor, receivesShadows: Bool, blended: Bool, shadowOnly: Bool) -> BatchTemplate {
        let pbr = material as? PBRMaterial
        if shadowOnly {
            // The shadow vertex shader only reads transform, alpha and fade.
            return BatchTemplate(color: pbr?.baseColorFactor ?? .one, material: .zero, textureFlags: .zero, shadowFlags: .zero, blended: false, rank: -1)
        }
        let atmosphere = material as? AtmosphereMaterial
        func hasUV(_ slot: Int) -> Bool {
            let set = pbr?.textureCoordinates.indices.contains(slot) == true ? pbr?.textureCoordinates[slot] ?? 0 : 0
            return descriptor.attributes.containsAttribute(by: set == 1 ? MeshDescriptor.textureCoordinates1.id.name : MeshDescriptor.textureCoordinates.id.name)
        }
        return BatchTemplate(
            color: pbr?.baseColorFactor ?? .one,
            material: [pbr?.roughnessFactor ?? 1, pbr?.metallicFactor ?? 0, pbr?.emissiveStrength ?? 0, pbr?.emissiveLightThreshold ?? -1],
            textureFlags: [
                hasUV(0) && pbr?.baseColorTexture != nil ? 1 : 0,
                hasUV(1) && pbr?.metallicRoughnessTexture != nil ? 1 : 0,
                hasUV(2) && pbr?.normalTexture != nil ? 1 : 0,
                descriptor.attributes.containsAttribute(by: MeshDescriptor.tangents.id.name) ? 1 : 0,
            ],
            shadowFlags: [receivesShadows ? 1 : 0, atmosphere?.fresnelPower ?? 0, atmosphere?.atmosphereIntensity ?? 0, 0],
            blended: blended,
            rank: -1
        )
    }
}
