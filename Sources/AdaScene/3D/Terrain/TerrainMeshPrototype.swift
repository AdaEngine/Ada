import AdaCorePipelines
@_spi(Internal) import AdaRender
import Foundation
import Math

/// A prepared static model shared by terrain placement cells. Preparation retains imported buffers
/// and the complete material table; it does not create entities or clone materials.
public struct TerrainMeshPrototype: Sendable {
    let collisionGeometryID = UUID()
    public struct Part: Sendable {
        public let nodeIndex: Int
        public let mesh: Mesh
        public let transform: Transform3D
    }
    public static let maximumNodes = 4_096
    public static let maximumDrawParts = 64
    public static let maximumPlacementsPerCell = 65_536
    public static let maximumDrawInstancesPerCell = 262_144
    public static let maximumExpandedBytes = 128 * 1_024 * 1_024
    public let parts: [Part]
    public let materials: [Material]
    public let bounds: AABB
    public let drawPartCount: Int
    /// Source vertex/index GPU buffers plus conservative CPU geometry/derived-cluster storage.
    /// Shared textures/materials and renderer pass buffers have separate asset/backend costs.
    public let retainedGeometryBytes: Int

    /// Selects the requested imported scene, or its default scene. Animated/deformed nodes are
    /// unsupported; use ordinary model entities for those assets.
    public init(model: ModelAsset3D, scene: Int? = nil) throws {
        guard model.nodes.count <= Self.maximumNodes, model.materials.count <= 256 else {
            throw TerrainMeshPrototypeError.budgetExceeded
        }
        let selected = scene ?? model.defaultScene ?? 0
        guard model.scenes.indices.contains(selected) else {
            throw TerrainMeshPrototypeError.invalidScene
        }
        guard model.animationClips.isEmpty, model.voxelTimeline == nil else {
            throw TerrainMeshPrototypeError.unsupportedDeformation
        }
        let roots = model.scenes[selected]
        guard roots.count <= Self.maximumNodes else {
            throw TerrainMeshPrototypeError.budgetExceeded
        }
        var stack = roots.reversed().map { (index: $0, parent: Transform3D.identity) }
        var visited: Set<Int> = []
        var prepared: [Part] = []
        var combinedBounds: AABB?
        var drawParts = 0
        var validatedMeshes: Set<Int> = []
        var geometryBudget = TerrainPrototypeGeometryBudget()
        while let entry = stack.popLast() {
            guard model.nodes.indices.contains(entry.index), visited.insert(entry.index).inserted else {
                throw TerrainMeshPrototypeError.invalidHierarchy
            }
            let node = model.nodes[entry.index]
            guard node.skinIndex == nil, node.voxelAnimation == nil, node.morphWeights?.isEmpty != false else {
                throw TerrainMeshPrototypeError.unsupportedDeformation
            }
            let local = node.restPose?.matrix ?? node.transform
            let transform = entry.parent * local
            guard Self.valid(local), Self.valid(transform) else {
                throw TerrainMeshPrototypeError.invalidTransform
            }
            if let index = node.meshIndex {
                guard model.meshes.indices.contains(index) else {
                    throw TerrainMeshPrototypeError.invalidHierarchy
                }
                let mesh = model.meshes[index]
                guard !mesh.hasMorphTargets else {
                    throw TerrainMeshPrototypeError.unsupportedDeformation
                }
                guard mesh.models.count <= Self.maximumDrawParts else {
                    throw TerrainMeshPrototypeError.budgetExceeded
                }
                if validatedMeshes.insert(index).inserted {
                    try Self.validateGeometry(mesh, budget: &geometryBudget)
                }
                var hasGeometry = false
                for group in mesh.models {
                    guard group.parts.count <= Self.maximumDrawParts - drawParts else {
                        throw TerrainMeshPrototypeError.budgetExceeded
                    }
                    drawParts += group.parts.count
                    for part in group.parts {
                        guard model.materials.indices.contains(part.materialIndex) else {
                            throw TerrainMeshPrototypeError.invalidMaterial
                        }
                        guard part.primitiveTopology == .triangleList, part.indexCount >= 0 else {
                            throw TerrainMeshPrototypeError.unsupportedGeometry
                        }
                        hasGeometry = hasGeometry || part.indexCount >= 3
                    }
                }
                if hasGeometry {
                    let box = MeshVisibility3DMath.transformed(mesh.bounds, by: transform)
                    guard box.min.x.isFinite, box.min.y.isFinite, box.min.z.isFinite,
                        box.max.x.isFinite, box.max.y.isFinite, box.max.z.isFinite
                    else {
                        throw TerrainMeshPrototypeError.invalidTransform
                    }
                    if let current = combinedBounds {
                        combinedBounds = AABB(min: min(current.min, box.min), max: max(current.max, box.max))
                    } else {
                        combinedBounds = box
                    }
                    prepared.append(Part(nodeIndex: entry.index, mesh: mesh, transform: transform))
                }
            }
            guard node.children.count <= Self.maximumNodes - stack.count else {
                throw TerrainMeshPrototypeError.budgetExceeded
            }
            for child in node.children.reversed() { stack.append((index: child, parent: transform)) }
        }
        guard !prepared.isEmpty, let combinedBounds else {
            throw TerrainMeshPrototypeError.emptyModel
        }
        guard combinedBounds.min.x.isFinite, combinedBounds.min.y.isFinite, combinedBounds.min.z.isFinite,
            combinedBounds.max.x.isFinite, combinedBounds.max.y.isFinite, combinedBounds.max.z.isFinite
        else {
            throw TerrainMeshPrototypeError.invalidTransform
        }
        self.drawPartCount = drawParts
        self.retainedGeometryBytes = Self.geometryBytes(prepared)
        self.parts = prepared
        self.materials = model.materials
        self.bounds = combinedBounds
    }

    /// Expands one cell only when placements change. Each imported mesh node gets one shared batch;
    /// each matrix is placement * imported-node, beneath the owning terrain transform.
    /// The byte budget covers expanded placement records, excluding shared mesh/material assets.
    public func makeBatches(
        instances: [Mesh3DInstance],
        maximumExpandedBytes: Int = 64 * 1_024 * 1_024,
        castShadows: Bool = true,
        receiveShadows: Bool = true
    ) throws -> [Mesh3DInstancesComponent] {
        guard (0...Self.maximumExpandedBytes).contains(maximumExpandedBytes), instances.count <= Self.maximumPlacementsPerCell,
            instances.count <= Self.maximumDrawInstancesPerCell / max(1, drawPartCount),
            instances.count <= maximumExpandedBytes / MemoryLayout<Mesh3DInstance>.stride / max(1, parts.count)
        else {
            throw TerrainMeshPrototypeError.budgetExceeded
        }
        if instances.isEmpty {
            return []
        }
        var ids: Set<UInt64> = []
        ids.reserveCapacity(instances.count)
        for instance in instances {
            guard ids.insert(instance.id).inserted, Self.valid(instance.transform),
                (0...1).contains(instance.color.x), (0...1).contains(instance.color.y),
                (0...1).contains(instance.color.z), (0...1).contains(instance.color.w)
            else {
                throw TerrainMeshPrototypeError.invalidPlacement
            }
        }
        return try parts.map { part in
            let placements = try instances.map { instance in
                var placement = instance
                placement.transform = instance.transform * part.transform
                guard Self.valid(placement.transform) else {
                    throw TerrainMeshPrototypeError.invalidPlacement
                }
                guard Self.valid(MeshVisibility3DMath.transformed(part.mesh.bounds, by: placement.transform)) else {
                    throw TerrainMeshPrototypeError.invalidPlacement
                }
                return placement
            }
            return Mesh3DInstancesComponent(mesh: part.mesh, materials: materials, instances: placements, castShadows: castShadows, receiveShadows: receiveShadows)
        }
    }

    private static func geometryBytes(_ parts: [Part]) -> Int {
        var vertexBuffers: Set<ObjectIdentifier> = [], indexBuffers: Set<ObjectIdentifier> = []
        var clusters: Set<UUID> = [], hierarchies: Set<UUID> = []
        var bytes = 0
        func include(_ count: Int, stride: Int = 1) {
            let (cost, productOverflow) = count.multipliedReportingOverflow(by: stride)
            let (total, sumOverflow) = bytes.addingReportingOverflow(cost)
            bytes = productOverflow || sumOverflow ? Int.max : total
        }
        func includeClusters(_ geometry: MeshletGeometry) {
            guard clusters.insert(geometry.id).inserted else {
                return
            }
            include(geometry.clusters.count, stride: MemoryLayout<MeshletCluster>.stride)
            include(geometry.indices.count, stride: MemoryLayout<UInt32>.stride)
        }
        for node in parts {
            for model in node.mesh.models {
                for part in model.parts {
                    if vertexBuffers.insert(ObjectIdentifier(part.vertexBuffer)).inserted {
                        include(part.vertexBuffer.length)
                        include(part.meshDescriptor.getVertexBufferSize())
                    }
                    if indexBuffers.insert(ObjectIdentifier(part.indexBuffer)).inserted {
                        include(part.indexBuffer.length)
                        include(part.meshDescriptor.indicies.count, stride: MemoryLayout<UInt32>.stride)
                    }
                    if let geometry = part.meshlets { includeClusters(geometry) }
                    if let hierarchy = part.meshletLOD, hierarchies.insert(hierarchy.id).inserted {
                        includeClusters(hierarchy.geometry)
                        include(hierarchy.nodes.count, stride: MemoryLayout<MeshletLODNode>.stride)
                        include(hierarchy.roots.count, stride: MemoryLayout<Int>.stride)
                    }
                }
            }
        }
        return bytes
    }

    private static func valid(_ bounds: AABB) -> Bool {
        func finite(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
        return finite(bounds.center) && finite(bounds.halfExtents) && finite(bounds.min) && finite(bounds.max)
            && bounds.halfExtents.x >= 0 && bounds.halfExtents.y >= 0 && bounds.halfExtents.z >= 0
    }

    private static func valid(_ matrix: Transform3D) -> Bool {
        func finite(_ value: Vector4) -> Bool {
            value.x.isFinite && value.y.isFinite && value.z.isFinite && value.w.isFinite
        }
        guard finite(matrix.x), finite(matrix.y), finite(matrix.z), finite(matrix.w),
            matrix.x.w == 0, matrix.y.w == 0, matrix.z.w == 0, matrix.w.w == 1
        else {
            return false
        }
        let determinant = matrix.x.xyz.dot(matrix.y.xyz.cross(matrix.z.xyz))
        guard determinant.isFinite, determinant != 0 else {
            return false
        }
        let inverse = matrix.inverse
        return finite(inverse.x) && finite(inverse.y) && finite(inverse.z) && finite(inverse.w)
    }
}

public enum TerrainMeshPrototypeError: LocalizedError, Equatable {
    case invalidScene, invalidHierarchy, invalidTransform, invalidMaterial, invalidPlacement
    case unsupportedDeformation, unsupportedGeometry, budgetExceeded, emptyModel

    public var errorDescription: String? {
        switch self {
        case .invalidScene: "The model has no matching scene"
        case .invalidHierarchy: "The model contains a missing, cyclic or multiply referenced node"
        case .invalidTransform: "The model contains a nonfinite, projective or noninvertible transform"
        case .invalidMaterial: "A model primitive references a missing material"
        case .invalidPlacement: "Placements require unique IDs, invertible finite transforms and normalized tints"
        case .unsupportedDeformation: "Terrain prototypes require static models without animation, skinning or morph targets"
        case .unsupportedGeometry: "Terrain prototypes require valid indexed triangle geometry with standard finite vertex attributes"
        case .budgetExceeded: "The terrain prototype or its expanded placement cell exceeds its budget"
        case .emptyModel: "The selected model scene has no renderable geometry"
        }
    }
}
