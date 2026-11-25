import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Foundation
import Math

/// Places and manages decals on an individual opaque 3D mesh entity.
@MainActor
public enum Decal3D {
    public struct Handle: Hashable, Sendable {
        private let id = UUID()
    }

    public struct Projector: Sendable {
        /// World-space frame. Local -Z points toward the receiver and +Y is the top of the image.
        public var transform: Transform3D
        /// Full width, height, and depth in projector space.
        public var size: Vector3
        /// Minimum dot product between the surface normal and the projector's +Z axis.
        public var minimumFacingDot: Float

        /// An upright projection frame at a surface hit, with roll around its outward normal.
        public static func surfaceFrame(point: Vector3, normal: Vector3, rotationDegrees: Float = 0) -> Transform3D? {
            let length = normal.length
            guard length.isFinite, length > 0, point.x.isFinite, point.y.isFinite, point.z.isFinite, rotationDegrees.isFinite else {
                return nil
            }
            let z = normal / length
            let up = abs(z.dot(.up)) > 0.99 ? Vector3(0, 0, 1) : .up
            let x = up.cross(z).normalized
            let y = z.cross(x)
            let radians = rotationDegrees.truncatingRemainder(dividingBy: 360) * .pi / 180
            let cosine = Math.cos(radians)
            let sine = Math.sin(radians)
            return Transform3D(Vector4(x * cosine + y * sine, 0), Vector4(y * cosine - x * sine, 0), Vector4(z, 0), Vector4(point, 1))
        }

        public init(transform: Transform3D, size: Vector3, minimumFacingDot: Float = 0.25) {
            self.transform = transform
            self.size = size
            self.minimumFacingDot = minimumFacingDot
        }
    }

    public struct Appearance: Sendable {
        /// Color pixels in sRGB with alpha coverage.
        public var color: Image
        /// Optional linear tangent-space normal image with +Y along increasing texture V.
        public var normal: Image?
        /// Optional linear roughness image using the red channel.
        public var roughness: Image?
        /// Higher priorities draw on top. Ties are resolved by creation order.
        public var priority: Int

        public init(color: Image, normal: Image? = nil, roughness: Image? = nil, priority: Int = 0) {
            self.color = color
            self.normal = normal
            self.roughness = roughness
            self.priority = priority
        }
    }

    public enum PlacementError: Error, Equatable, Sendable {
        case unsupportedBackend
        case unsupportedReceiver
        case invalidProjector
        case invalidAppearance
        case missingPart
        case missesReceiver
        case capacityExceeded
        case staleHandle
    }

    struct Projection: Sendable {
        let part: Mesh.Part
        let triangles: [Int: [Vector3]]
    }

    struct Entry: Sendable {
        let handle: Handle
        var appearance: Appearance
        var authoredOrder: Int?
        var projections: [Decal3DPartKey: Projection]
    }

    struct State: Sendable {
        let receiver: ObjectIdentifier
        let meshRevision: RID
        let topology: [Decal3DPartKey]
        var lodTopology: [[Decal3DPartKey]]?
        var entries: [Entry]
        var draws: [Decal3DPartKey: Decal3DDraw] = [:]
        var revision = RID()

        nonisolated func matches(_ entity: Entity, mesh: Mesh3DComponent) -> Bool {
            receiver == ObjectIdentifier(entity) && meshRevision == mesh.geometryRevision
                && topology == Decal3DStorage.topology(of: mesh.mesh)
        }

        mutating func pinToSource() {
            guard lodTopology != nil else {
                return
            }
            let source = Set(topology)
            for index in entries.indices {
                entries[index].projections = entries[index].projections.filter { source.contains($0.key) }
            }
            draws = draws.filter { source.contains($0.key) }
            lodTopology = nil
            revision = RID()
        }
    }

    public static var isSupported: Bool {
        unsafe RenderEngine.shared?.type == .saga
    }

    static func contains(_ handle: Handle, on receiver: Entity) -> Bool {
        guard let mesh = receiver.components[Mesh3DComponent.self],
              let state = receiver.world?.getResource(Decal3DStorage.self)?.receivers[receiver.id],
              state.matches(receiver, mesh: mesh) else { return false }
        return state.entries.contains { $0.handle == handle }
    }

    /// Stamps the mesh in its most recently evaluated pose. For a skinned mesh, call after pose evaluation
    /// when changing the pose and stamping it in the same update. The optional part ID addresses the mesh's parts.
    @discardableResult
    public static func place(
        on receiver: Entity,
        projector: Projector,
        appearance: Appearance,
        part partID: Int? = nil
    ) throws(PlacementError) -> Handle {
        try place(on: receiver, projector: projector, appearance: appearance, part: partID, replacing: nil)
    }

    static func place(
        on receiver: Entity,
        projector: Projector,
        appearance: Appearance,
        part partID: Int?,
        replacing: Handle?,
        authoredOrder: Int? = nil
    ) throws(PlacementError) -> Handle {
        guard let engine = unsafe RenderEngine.shared, engine.type == .saga else { throw .unsupportedBackend }
        guard let component = receiver.components[Mesh3DComponent.self], let world = receiver.world,
            let storage = world.getResource(Decal3DStorage.self), receiver.components[MeshTerrain3DSourceMask.self] == nil
        else { throw .unsupportedReceiver }
        let device = engine.renderDevice
        let receiverLocal = authoredOrder != nil
        let receiverFrame = if receiverLocal { Transform3D.identity } else { try receiverWorldTransform(receiver) }
        let projection = try ProjectionFrame(projector, receiverWorld: receiverFrame, compareFacingInProjectorSpace: receiverLocal)
        let skin = receiver.components[SkinnedMesh3DComponent.self]?.matrices
        let morphs = receiver.components[MorphWeights3DComponent.self]?.weights ?? []
        let deforms = skin != nil || component.mesh.hasMorphTargets
        let alternatives = receiver.components[MeshLOD3DComponent.self]?.alternatives ?? []
        let lodTopology = deforms ? nil : alternatives.map(Decal3DStorage.topology)
        var state = storage.receivers[receiver.id].flatMap { $0.matches(receiver, mesh: component) ? $0 : nil } ?? State(
            receiver: ObjectIdentifier(receiver),
            meshRevision: component.geometryRevision,
            topology: Decal3DStorage.topology(of: component.mesh),
            lodTopology: lodTopology,
            entries: []
        )
        if state.lodTopology != lodTopology { state.pinToSource() }
        let lods = state.lodTopology == nil ? [] : alternatives
        let replacement = replacing.flatMap { handle in state.entries.firstIndex { $0.handle == handle } }
        if replacing != nil, replacement == nil { throw .staleHandle }
        guard replacement != nil || state.entries.count < Decal3DResources.maximumDecals else { throw .capacityExceeded }
        try Decal3DResources.validate(appearance)

        var projections: [Decal3DPartKey: Projection] = [:]
        var foundPart = false
        var supportedPart = false
        var projectedTriangleCount = 0
        var remainingScan = Decal3DResources.maximumScannedTriangles
        for (level, mesh) in ([component.mesh] + lods).enumerated() {
            var covered = false
            for part in mesh.models.flatMap(\.parts) where partID == nil || part.id == partID {
                foundPart = true
                guard component.materials.indices.contains(part.materialIndex), let material = component.materials[part.materialIndex] as? PBRMaterial,
                    supports(material), part.primitiveTopology == .triangleList, part.canExpandForDecals,
                    part.indexCount == part.meshDescriptor.indicies.count
                else { continue }
                supportedPart = true
                let key = Decal3DPartKey(part)
                if projections[key] != nil {
                    covered = true
                    continue
                }
                let frames = part.indexCount / 3
                guard frames <= remainingScan else { throw .capacityExceeded }
                remainingScan -= frames
                let triangles = try projectedTriangles(part, frame: projection, skin: skin, morphs: morphs)
                projectedTriangleCount += triangles.count
                guard projectedTriangleCount <= Decal3DResources.maximumStampedTriangles else { throw .capacityExceeded }
                if !triangles.isEmpty {
                    projections[key] = Projection(part: part, triangles: triangles)
                    covered = true
                }
            }
            if !covered {
                if level > 0 {
                    state.pinToSource()
                    let source = Set(state.topology)
                    projections = projections.filter { source.contains($0.key) }
                }
                break
            }
        }
        guard foundPart else { throw .missingPart }
        guard supportedPart else { throw .unsupportedReceiver }
        guard !projections.isEmpty else { throw .missesReceiver }

        let handle = replacing ?? Handle()
        let entry = Entry(handle: handle, appearance: appearance, authoredOrder: authoredOrder, projections: projections)
        if let replacement {
            state.entries[replacement] = entry
        } else {
            state.entries.append(entry)
        }
        state.draws = try Decal3DResources.build(state, device: device)
        state.revision = RID()
        world.getRefResource(Decal3DStorage.self).wrappedValue.set(state, for: receiver.id)
        return handle
    }

    /// Changes an existing decal's appearance without projecting against a new pose.
    public static func update(_ handle: Handle, on receiver: Entity, appearance: Appearance) throws(PlacementError) {
        try edit(handle, on: receiver, appearance: appearance, authoredOrder: nil)
    }

    static func updateAuthored(
        _ handle: Handle, on receiver: Entity, appearance: Appearance, order: Int
    ) throws(PlacementError) {
        try edit(handle, on: receiver, appearance: appearance, authoredOrder: order)
    }

    /// Removes a decal and releases the geometry constraint after the last attachment.
    public static func remove(_ handle: Handle, from receiver: Entity) throws(PlacementError) {
        try edit(handle, on: receiver, appearance: nil, authoredOrder: nil)
    }

    nonisolated static func supports(_ material: PBRMaterial) -> Bool {
        material.effectiveAlphaMode == .opaque && material.graphMaterial == nil && material.terrainBindings == nil
    }

    private static func edit(
        _ handle: Handle, on receiver: Entity, appearance: Appearance?, authoredOrder: Int?
    ) throws(PlacementError) {
        guard let component = receiver.components[Mesh3DComponent.self], let world = receiver.world,
            var state = world.getResource(Decal3DStorage.self)?.receivers[receiver.id], state.matches(receiver, mesh: component),
            let index = state.entries.firstIndex(where: { $0.handle == handle }),
            let device = unsafe RenderEngine.shared?.renderDevice
        else { throw .staleHandle }
        if let appearance {
            try Decal3DResources.validate(appearance)
            state.entries[index].appearance = appearance
            if let authoredOrder { state.entries[index].authoredOrder = authoredOrder }
        } else {
            state.entries.remove(at: index)
        }
        let storage = world.getRefResource(Decal3DStorage.self)
        if state.entries.isEmpty {
            storage.wrappedValue.set(nil, for: receiver.id)
        } else {
            state.draws = try Decal3DResources.build(state, device: device)
            state.revision = RID()
            storage.wrappedValue.set(state, for: receiver.id)
        }
    }

    private static func receiverWorldTransform(_ receiver: Entity) throws(PlacementError) -> Transform3D {
        guard let local = receiver.components[Transform.self] else {
            return receiver.components[GlobalTransform.self]?.matrix ?? .identity
        }
        var matrix = local.matrix
        var current = receiver.parent
        var ancestors: Set<Entity.ID> = [receiver.id]
        while let entity = current, let parentTransform = entity.components[Transform.self] {
            guard ancestors.insert(entity.id).inserted else { throw .unsupportedReceiver }
            matrix = parentTransform.matrix * matrix
            current = entity.parent
        }
        return matrix
    }
}

struct Decal3DStorage: Resource, Sendable {
    private(set) var receivers: [Entity.ID: Decal3D.State] = [:]
    private(set) var revision = RID()

    mutating func set(_ state: Decal3D.State?, for receiver: Entity.ID) {
        receivers[receiver] = state
        revision = RID()
    }

    static func topology(of mesh: Mesh) -> [Decal3DPartKey] {
        mesh.models.flatMap { $0.parts.map(Decal3DPartKey.init) }
    }
}

@PlainSystem
struct Decal3DCleanupSystem {
    @ResMut<Decal3DStorage> private var storage
    @Query<Mesh3DComponent> private var meshAccess
    @Query<MeshLOD3DComponent> private var lodAccess

    init(world _: World) {}

    func update(context: UpdateContext) {
        _ = meshAccess.wrappedValue
        _ = lodAccess.wrappedValue
        for (id, state) in storage.receivers {
            guard let entity = context.world.getEntityByID(id), let component = entity.components[Mesh3DComponent.self],
                state.matches(entity, mesh: component)
            else {
                storage.set(nil, for: id)
                continue
            }
            if let lodTopology = state.lodTopology,
                lodTopology != (entity.components[MeshLOD3DComponent.self]?.alternatives ?? []).map(Decal3DStorage.topology) {
                var pinned = state
                pinned.pinToSource()
                storage.set(pinned, for: id)
            }
        }
    }
}

extension Decal3D {
    private struct ProjectionFrame {
        let receiverWorld: Transform3D
        let normalizedFromWorld: Transform3D
        let facing: Vector3
        let minimumFacingDot: Float
        let projectorFacingFrame: Transform3D?
        let projectorOrientation: Float

        init(_ projector: Projector, receiverWorld: Transform3D, compareFacingInProjectorSpace: Bool) throws(PlacementError) {
            let pose = projector.transform
            let size = projector.size
            guard [pose, receiverWorld].allSatisfy(Self.isAffine),
                size.x.isFinite, size.y.isFinite, size.z.isFinite, size.x > 0, size.y > 0, size.z > 0,
                (0...1).contains(projector.minimumFacingDot)
            else { throw .invalidProjector }
            let scale = Vector3(2 / size.x, 2 / size.y, 2 / size.z)
            let projectorFromWorld = pose.inverse
            let normalizedFromWorld = Transform3D(scale: scale) * projectorFromWorld
            let facing = pose.z.xyz.normalized
            guard Self.isAffine(normalizedFromWorld), facing.length > 0 else { throw .invalidProjector }
            self.receiverWorld = receiverWorld
            self.normalizedFromWorld = normalizedFromWorld
            self.facing = compareFacingInProjectorSpace ? Vector3(0, 0, 1) : facing
            projectorFacingFrame = compareFacingInProjectorSpace ? projectorFromWorld : nil
            projectorOrientation = compareFacingInProjectorSpace && pose.determinant < 0 ? -1 : 1
            minimumFacingDot = projector.minimumFacingDot
        }

        private static func isAffine(_ matrix: Transform3D) -> Bool {
            guard abs(matrix.x.w) < 0.000001, abs(matrix.y.w) < 0.000001, abs(matrix.z.w) < 0.000001, abs(matrix.w.w - 1) < 0.000001,
                matrix.determinant.isFinite, matrix.determinant != 0
            else { return false }
            return (0..<4).allSatisfy { column in (0..<4).allSatisfy { matrix[column, $0].isFinite } }
        }
    }

    private static func projectedTriangles(
        _ part: Mesh.Part,
        frame: ProjectionFrame,
        skin: [Transform3D]?,
        morphs: [Float]
    ) throws(PlacementError) -> [Int: [Vector3]] {
        let descriptor = part.meshDescriptor
        let indices = descriptor.indicies
        guard descriptor.positions.count <= Decal3DResources.maximumScannedTriangles * 3 else { throw .capacityExceeded }
        let positions = descriptor.positions.elements
        guard indices.count.isMultiple(of: 3), indices.allSatisfy({ Int($0) < positions.count }) else { throw .unsupportedReceiver }
        let joints = descriptor[MeshDescriptor.jointIndices]?.elements ?? []
        let influences = descriptor[MeshDescriptor.jointWeights]?.elements ?? []
        let morphSet = part.morphTargets
        let active = MorphTargetSet.activeTargets(weights: morphs).filter { $0.index < (morphSet?.targetCount ?? 0) }
        var worldPositions: [Vector3] = []
        var orientations: [Float] = []
        worldPositions.reserveCapacity(positions.count)
        orientations.reserveCapacity(positions.count)
        for (index, position) in positions.enumerated() {
            var posed = position
            if let morphSet {
                for (target, weight) in active {
                    posed += morphSet.renderPositionDelta(target: target, vertex: index) * weight
                }
            }
            var transform = frame.receiverWorld
            if let skin, joints.indices.contains(index), influences.indices.contains(index), joints[index].x >= 0 {
                var matrix = Transform3D(.zero, .zero, .zero, .zero)
                for slot in 0..<4 {
                    let joint = joints[index][slot]
                    guard joint >= 0, joint < Float(skin.count) else { throw .unsupportedReceiver }
                    let influence = skin[Int(joint)] * influences[index][slot]
                    matrix.x += influence.x
                    matrix.y += influence.y
                    matrix.z += influence.z
                    matrix.w += influence.w
                }
                transform = frame.receiverWorld * matrix
            }
            worldPositions.append((transform * Vector4(posed, 1)).xyz)
            orientations.append(transform.determinant < 0 ? -1 : 1)
        }
        let projected = worldPositions.map { (frame.normalizedFromWorld * Vector4($0, 1)).xyz }
        var result: [Int: [Vector3]] = [:]
        for offset in stride(from: 0, to: indices.count, by: 3) {
            let a = Int(indices[offset]), b = Int(indices[offset + 1]), c = Int(indices[offset + 2])
            let first = projected[a], second = projected[b], third = projected[c]
            let low = min(min(first, second), third), high = max(max(first, second), third)
            guard low.x <= 1, low.y <= 1, low.z <= 1, high.x >= -1, high.y >= -1, high.z >= -1 else { continue }
            var firstEdge = worldPositions[b] - worldPositions[a]
            var secondEdge = worldPositions[c] - worldPositions[a]
            if let projectorFrame = frame.projectorFacingFrame {
                firstEdge = (projectorFrame * Vector4(firstEdge, 0)).xyz
                secondEdge = (projectorFrame * Vector4(secondEdge, 0)).xyz
            }
            let normal = firstEdge.cross(secondEdge)
            guard normal.length > 0, normal.normalized.dot(frame.facing) * orientations[a] * frame.projectorOrientation >= frame.minimumFacingDot,
                !DecalTriangle3D.clip(first, second, third).isEmpty
            else { continue }
            result[offset / 3] = [first, second, third]
            guard result.count <= Decal3DResources.maximumStampedTriangles else { throw .capacityExceeded }
        }
        return result
    }
}
