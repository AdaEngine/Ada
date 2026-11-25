@_spi(AdaEngine) import AdaAssets
import AdaECS
import AdaRender
import AdaUtils
import Foundation
import Math
import Observation

/// Scene-owned decal references. Runtime handles and decoded image pixels remain transient.
public struct Decal3DSource: Component, Codable, Equatable {
    public struct ModelNode: Codable, Hashable, Sendable {
        public var source: String
        public var index: Int
        public var name: String

        public init(source: String, index: Int, name: String) {
            self.source = source
            self.index = index
            self.name = name
        }
    }

    public struct Entry: Codable, Equatable, Identifiable, Sendable {
        public var id: UUID
        public var node: ModelNode?
        public var localFrame: Transform3D
        public var size: Vector3
        public var rotationDegrees: Float
        public var images: Decal3DImages

        public init(
            id: UUID = UUID(),
            node: ModelNode? = nil,
            localFrame: Transform3D,
            size: Vector3,
            rotationDegrees: Float = 0,
            images: Decal3DImages
        ) {
            self.id = id
            self.node = node
            self.localFrame = localFrame
            self.size = size
            self.rotationDegrees = rotationDegrees
            self.images = images
        }

        func projector() throws(Decal3D.PlacementError) -> Decal3D.Projector {
            guard let roll = Decal3D.Projector.surfaceFrame(point: .zero, normal: Vector3(0, 0, 1), rotationDegrees: rotationDegrees) else {
                throw .invalidProjector
            }
            return .init(transform: localFrame * roll, size: size)
        }
    }

    public var entries: [Entry]

    public init(entries: [Entry] = []) {
        self.entries = entries
    }
}

/// Authoring errors are attached to their record so missing assets remain editable.
@MainActor
@Observable
public final class Decal3DSourceStatus: Resource {
    private var errors: [Entity.ID: [UUID: String]] = [:]
    @ObservationIgnored let publication = Decal3DSourceSystem.Publication()

    /// Commits a prepared editor edit at a world safe point. A failure leaves the published decal intact.
    @_spi(AdaEngine)
    public func applyEdit(
        _ entry: Decal3DSource.Entry, order: Int, on owner: Entity, appearance: Decal3D.Appearance
    ) throws(Decal3D.PlacementError) {
        guard let world = owner.world else { throw .unsupportedReceiver }
        let key = Decal3DSourceSystem.Publication.Key(owner: owner.id, entry: entry.id)
        try publication.applyEdit(entry, order: order, key: key, owner: owner, world: world, appearance: appearance)
        set(nil, for: owner.id, entry: entry.id)
    }

    @MainActor
    public func error(for owner: Entity.ID, entry: UUID) -> String? {
        errors[owner]?[entry]
    }

    @MainActor
    func set(_ code: String?, for owner: Entity.ID, entry: UUID) {
        guard errors[owner]?[entry] != code else {
            return
        }
        errors[owner, default: [:]][entry] = code
        if errors[owner]?.isEmpty == true { errors.removeValue(forKey: owner) }
    }
}

struct Decal3DSourceSystem: System {
    @Query<Entity, Decal3DSource> private var documents
    @Res<Decal3DSourceStatus> private var status
    var queries: SystemQueries { SystemQueries(queries: [_documents, _status, ExclusiveWorldAccess()]) }

    static let dependencies: [SystemDependency] = [.after(Decal3DCleanupSystem.self), .before(Decal3DCommandSystem.self)]

    init(world _: World) {}

    @MainActor
    func update(context: UpdateContext) {
        guard Decal3D.isSupported else {
            return
        }
        let publication = status.publication
        var active: Set<Publication.Key> = []
        documents.forEach { owner, source in
            var loadingNodes: Set<Decal3DSource.ModelNode?> = []
            for (order, entry) in source.entries.prefix(64).enumerated() {
                let key = Publication.Key(owner: owner.id, entry: entry.id)
                guard active.insert(key).inserted else { continue }
                publication.prepare(
                    entry,
                    order: order,
                    key: key,
                    owner: owner,
                    world: context.world,
                    status: status,
                    canPublish: !loadingNodes.contains(entry.node)
                )
                if let state = publication.entries[key], state.applied == nil, state.pending != nil {
                    loadingNodes.insert(entry.node)
                }
            }
        }
        for key in publication.entries.keys where !active.contains(key) {
            publication.remove(key, world: context.world, status: status)
        }
    }

    final class Publication: Sendable {
        struct Key: Hashable {
            let owner: Entity.ID
            let entry: UUID
        }

        struct Applied {
            let receiver: Entity.ID
            let handle: Decal3D.Handle
            let definition: Decal3DSource.Entry
            let appearance: Decal3D.Appearance
            let order: Int
        }

        @MainActor
        final class Pending {
            let definition: Decal3DSource.Entry
            var task: Task<Void, Never>?
            var appearance: Decal3D.Appearance?
            var finished = false

            init(_ definition: Decal3DSource.Entry) { self.definition = definition }
            deinit { task?.cancel() }
        }

        struct ResolvedNode {
            let locator: Decal3DSource.ModelNode
            let source: String
            let root: Entity.ID
            let receiver: Entity.ID?
        }

        struct State {
            var resolvedNode: ResolvedNode?
            var applied: Applied?
            var pending: Pending?
            var failed: Decal3DSource.Entry?
            var failedReceiver: ObjectIdentifier?
            var failedRevision: RID?
            var failedDecalRevision: RID?
            var capacityFailure = false
        }

        @MainActor var entries: [Key: State] = [:]

        @MainActor
        func prepare(
            _ entry: Decal3DSource.Entry, order: Int, key: Key, owner: Entity, world: World, status: Decal3DSourceStatus, canPublish: Bool
        ) {
            var state = entries[key] ?? State()
            defer { entries[key] = state }
            guard let receiver = Self.receiver(for: entry, owner: owner, world: world, previous: &state.resolvedNode) else {
                state.pending = nil
                if owner.components[Model3DSource.self] == nil || owner.components[Model3DSourceState.self] != nil {
                    if let applied = state.applied { remove(applied, world: world) }
                    state.applied = nil
                    status.set("missingReceiver", for: key.owner, entry: key.entry)
                }
                return
            }

            if let applied = state.applied, applied.receiver != receiver.id || !Decal3D.contains(applied.handle, on: receiver) {
                remove(applied, world: world)
                state.applied = nil
            }
            if state.applied?.definition == entry, state.applied?.order == order {
                state.pending = nil
                state.failed = nil
                status.set(nil, for: key.owner, entry: key.entry)
                return
            }

            let identity = ObjectIdentifier(receiver)
            let revision = receiver.components[Mesh3DComponent.self]?.extractionRevision
            let decalRevision = world.getResource(Decal3DStorage.self)?.receivers[receiver.id]?.revision
            if state.failed == entry, state.failedReceiver == identity, state.failedRevision == revision,
               !state.capacityFailure || state.failedDecalRevision == decalRevision {
                return
            }
            if state.pending?.definition != entry {
                let pending = Pending(entry)
                state.pending = pending
                if let applied = state.applied {
                    var previous = applied.definition.images
                    previous.priority = entry.images.priority
                    if previous == entry.images {
                        var appearance = applied.appearance
                        appearance.priority = entry.images.priority
                        pending.appearance = appearance
                        pending.finished = true
                    }
                }
                if !pending.finished {
                    pending.task = Task { @MainActor [weak pending] in
                        let appearance = try? await entry.images.load()
                        guard !Task.isCancelled, let pending else {
                            return
                        }
                        pending.appearance = appearance
                        pending.finished = true
                    }
                }
            }
            guard let pending = state.pending, pending.finished, canPublish else {
                return
            }
            state.pending = nil
            do {
                guard let appearance = pending.appearance else { throw Decal3DSourceError.assetLoadFailed }
                state.applied = try commit(entry, order: order, on: receiver, appearance: appearance, previous: state.applied, world: world)
                status.set(nil, for: key.owner, entry: key.entry)
            } catch {
                state.failed = entry
                state.failedReceiver = identity
                state.failedRevision = revision
                state.failedDecalRevision = decalRevision
                state.capacityFailure = (error as? Decal3D.PlacementError) == .capacityExceeded
                let code = String(describing: error)
                status.set(code, for: key.owner, entry: key.entry)
                RuntimeLogStore.shared.append(level: "warning", label: "Decal3D", message: "Decal on \(owner.name) failed: \(code).")
            }
        }

        @MainActor
        func applyEdit(
            _ entry: Decal3DSource.Entry, order: Int, key: Key, owner: Entity, world: World, appearance: Decal3D.Appearance
        ) throws(Decal3D.PlacementError) {
            var state = entries[key] ?? State()
            guard let receiver = Self.receiver(for: entry, owner: owner, world: world, previous: &state.resolvedNode) else { throw .unsupportedReceiver }
            let applied = try commit(entry, order: order, on: receiver, appearance: appearance, previous: state.applied, world: world)
            entries[key] = State(resolvedNode: state.resolvedNode, applied: applied)
        }

        @MainActor
        private func commit(
            _ entry: Decal3DSource.Entry, order: Int, on receiver: Entity, appearance: Decal3D.Appearance, previous: Applied?, world: World
        ) throws(Decal3D.PlacementError) -> Applied {
            let existing = previous.flatMap {
                $0.receiver == receiver.id && Decal3D.contains($0.handle, on: receiver) ? $0 : nil
            }
            let handle: Decal3D.Handle
            if let existing, existing.definition.localFrame == entry.localFrame,
               existing.definition.size == entry.size, existing.definition.rotationDegrees == entry.rotationDegrees,
               existing.definition.node == entry.node {
                try Decal3D.updateAuthored(existing.handle, on: receiver, appearance: appearance, order: order)
                handle = existing.handle
            } else {
                handle = try Decal3D.place(
                    on: receiver,
                    projector: entry.projector(),
                    appearance: appearance,
                    part: nil,
                    replacing: existing?.handle,
                    authoredOrder: order
                )
            }
            if let previous, previous.receiver != receiver.id { remove(previous, world: world) }
            return Applied(receiver: receiver.id, handle: handle, definition: entry, appearance: appearance, order: order)
        }

        @MainActor
        func remove(_ key: Key, world: World, status: Decal3DSourceStatus) {
            if let applied = entries.removeValue(forKey: key)?.applied { remove(applied, world: world) }
            status.set(nil, for: key.owner, entry: key.entry)
        }

        @MainActor
        private func remove(_ applied: Applied, world: World) {
            guard let receiver = world.getEntityByID(applied.receiver) else {
                return
            }
            try? Decal3D.remove(applied.handle, from: receiver)
        }

        @MainActor
        private static func receiver(
            for entry: Decal3DSource.Entry, owner: Entity, world: World, previous: inout ResolvedNode?
        ) -> Entity? {
            guard let node = entry.node else {
                previous = nil
                return supported(owner) ? owner : nil
            }
            guard let reference = owner.components[Model3DSource.self],
                  let rootID = owner.components[Model3DSourceState.self]?.rootEntityID,
                  let root = world.getEntityByID(rootID) else { return nil }
            if let previous, previous.locator == node, previous.source == reference.source, previous.root == rootID {
                guard let id = previous.receiver else {
                    return nil
                }
                if let entity = world.getEntityByID(id), supported(entity) {
                    return entity
                }
            }
            var target: Entity?
            if AssetsManager.resolveAssetURL(at: reference.source).standardizedFileURL
                == AssetsManager.resolveAssetURL(at: node.source).standardizedFileURL {
                var pending = [root]
                while let entity = pending.popLast() {
                    if let binding = entity.components[ModelNode3DComponent.self], binding.modelRoot == rootID,
                       binding.nodeIndex == node.index, entity.name == node.name {
                        if target != nil {
                            target = nil
                            break
                        }
                        target = entity
                    }
                    pending.append(contentsOf: entity.children)
                }
            }
            previous = ResolvedNode(locator: node, source: reference.source, root: rootID, receiver: target?.id)
            return target.flatMap { supported($0) ? $0 : nil }
        }

        @MainActor
        private static func supported(_ entity: Entity) -> Bool {
            guard let mesh = entity.components[Mesh3DComponent.self] else {
                return false
            }
            return entity.components[SkinnedMesh3DComponent.self] == nil && !mesh.mesh.hasMorphTargets
        }
    }
}

private enum Decal3DSourceError: Error {
    case assetLoadFailed
}
