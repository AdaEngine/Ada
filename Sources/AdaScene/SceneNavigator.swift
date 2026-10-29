import AdaAssets
import AdaECS
import Foundation

/// Errors raised by a scene navigation request.
public enum SceneNavigationError: Error, Sendable, LocalizedError {
    case noCurrentScene
    case superseded

    public var errorDescription: String? {
        switch self {
        case .noCurrentScene: "There is no active scene to reload."
        case .superseded: "A newer scene navigation request replaced this one."
        }
    }
}

/// Replaces the scene-owned part of one running world at a frame boundary.
/// Application resources that are not supplied by the scene remain in the world.
/// The lock protects request state shared with asset-loading tasks; world mutation runs only in setup or post-update.
public final class SceneNavigator: Resource, @unchecked Sendable {
    public struct LoadingProgress: Sendable {
        public let fraction: Double
        public let stage: String
        public init(fraction: Double, stage: String) {
            self.fraction = fraction
            self.stage = stage
        }
    }
    private enum Source: Sendable {
        case path(String)
        case factory(@MainActor @Sendable () throws -> Scene)
    }

    private struct PreviousResource: Sendable {
        let type: any Resource.Type
        let value: (any Resource)?
    }

    private struct ActiveScene: Sendable {
        let source: Source
        let root: Entity
        let previousResources: [PreviousResource]
        var spawnedEntityIDs: Set<Entity.ID>
    }

    private struct PreparedScene: Sendable {
        let generation: UInt64
        let scene: Scene
        let source: Source
        let completion: CheckedContinuation<Void, any Error>?
    }

    private let world: World
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var active: ActiveScene?
    private var prepared: PreparedScene?
    private var lastFailure: String?
    private var sceneLoader: (@Sendable (String, @escaping @Sendable (LoadingProgress) -> Void) async throws -> Scene)?
    private var progress = LoadingProgress(fraction: 0, stage: "idle")
    private var willReplaceHandlers: [@Sendable () -> Void] = []

    public init(world: World) {
        self.world = world
    }

    /// Path of the active asset scene, if it was loaded from a path.
    public var currentScenePath: String? {
        lock.withLock {
            if case let .path(path) = active?.source { path } else { nil }
        }
    }

    /// The last loading error. The active scene is retained when loading fails.
    public var lastError: String? { lock.withLock { lastFailure } }
    public var loadingProgress: LoadingProgress { lock.withLock { progress } }

    /// Override path loading for a host that uses a project-specific scene format.
    public func setSceneLoader(_ loader: @escaping @Sendable (String) async throws -> Scene) {
        setSceneLoader { path, _ in try await loader(path) }
    }

    /// Progress belongs to one request; callbacks from superseded loads are ignored.
    public func setSceneLoader(_ loader: @escaping @Sendable (String, @escaping @Sendable (LoadingProgress) -> Void) async throws -> Scene) {
        lock.withLock { sceneLoader = loader }
    }

    /// Register cleanup that runs immediately before an active scene is removed.
    public func onSceneWillReplace(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { willReplaceHandlers.append(handler) }
    }

    /// Load a fresh scene asset and replace the active scene on the next post-update pass.
    public func replaceScene(with path: String) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(.path(path), completion: continuation)
        }
    }

    /// Recreate the active scene from its original path or factory.
    public func reloadScene() async throws {
        guard let source = lock.withLock({ active?.source }) else {
            throw SceneNavigationError.noCurrentScene
        }
        try await withCheckedThrowingContinuation { continuation in
            enqueue(source, completion: continuation)
        }
    }

    /// Start a replacement without waiting for the next frame. Useful in synchronous callbacks.
    public func requestReplaceScene(
        with path: String,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) {
        enqueue(.path(path), completion: nil, onFailure: onFailure)
    }

    /// Start a restart without waiting for the next frame. Returns false if no scene is active.
    @discardableResult
    public func requestReloadScene(onFailure: (@Sendable (String) -> Void)? = nil) -> Bool {
        guard let source = lock.withLock({ active?.source }) else {
            return false
        }
        enqueue(source, completion: nil, onFailure: onFailure)
        return true
    }

    /// Mark a runtime-spawned entity as part of the active scene so reload removes it.
    public func trackSceneEntity(_ entityID: Entity.ID) {
        lock.withLock { _ = active?.spawnedEntityIDs.insert(entityID) }
    }

    /// Install the first scene during application setup. The factory must return fresh state on reload.
    @MainActor
    public func installInitialScene(
        _ scene: Scene,
        make: @escaping @MainActor @Sendable () throws -> Scene
    ) {
        install(scene, source: .factory(make), in: world)
    }

    @MainActor
    func applyPending(in world: World) {
        let candidate = lock.withLock { () -> PreparedScene? in
            defer { prepared = nil }
            return prepared
        }
        guard let candidate else { return }
        guard lock.withLock({ generation == candidate.generation }) else {
            candidate.completion?.resume(throwing: SceneNavigationError.superseded)
            return
        }
        install(candidate.scene, source: candidate.source, in: world)
        lock.withLock { progress = LoadingProgress(fraction: 1, stage: "ready") }
        candidate.completion?.resume()
    }

    private func enqueue(
        _ source: Source,
        completion: CheckedContinuation<Void, any Error>?,
        onFailure: (@Sendable (String) -> Void)? = nil
    ) {
        let request = lock.withLock { () -> UInt64 in
            generation &+= 1
            prepared?.completion?.resume(throwing: SceneNavigationError.superseded)
            prepared = nil
            lastFailure = nil
            progress = LoadingProgress(fraction: 0, stage: "reading")
            return generation
        }
        Task {
            do {
                let scene: Scene
                switch source {
                case let .path(path):
                    if let sceneLoader = lock.withLock({ sceneLoader }) {
                        scene = try await sceneLoader(path) { [weak self] update in
                            self?.lock.withLock {
                                guard self?.generation == request, self?.progress.stage != "failed", update.fraction.isFinite,
                                      let current = self?.progress, update.fraction >= current.fraction else { return }
                                self?.progress = LoadingProgress(fraction: min(0.99, max(0, update.fraction)), stage: update.stage)
                            }
                        }
                    } else {
                        scene = try unsafe await AssetsManager.loadFresh(Scene.self, at: path)
                    }
                case let .factory(make):
                    scene = try await MainActor.run { try make() }
                }
                lock.withLock {
                    guard generation == request else {
                        completion?.resume(throwing: SceneNavigationError.superseded)
                        return
                    }
                    prepared = PreparedScene(generation: request, scene: scene, source: source, completion: completion)
                    progress = LoadingProgress(fraction: 0.99, stage: "installing")
                }
            } catch {
                let message = error.localizedDescription
                let shouldReport = lock.withLock { () -> Bool in
                    guard generation == request else {
                        completion?.resume(throwing: SceneNavigationError.superseded)
                        return false
                    }
                    lastFailure = message
                    progress = LoadingProgress(fraction: progress.fraction, stage: "failed")
                    completion?.resume(throwing: error)
                    return true
                }
                if shouldReport { onFailure?(message) }
            }
        }
    }

    @MainActor
    private func install(_ scene: Scene, source: Source, in world: World) {
        let outgoing = lock.withLock { active }
        if let outgoing {
            let handlers = lock.withLock { willReplaceHandlers }
            for handler in handlers { handler() }
            world.removeEntity(outgoing.root, recursively: true)
            for entityID in outgoing.spawnedEntityIDs {
                world.removeEntity(entityID, recursively: true)
            }
            world.flush()
            for resource in outgoing.previousResources {
                if let value = resource.value {
                    world.insertResource(value)
                } else {
                    world.removeResource(resource.type)
                }
            }
        }

        let root = world.spawn("Scene: \(scene.name)") {}
        let sceneEntities = scene.world.getEntities()
        var copies: [Entity.ID: Entity] = [:]
        copies.reserveCapacity(sceneEntities.count)
        for entity in sceneEntities where entity.parent == nil {
            copyHierarchy(from: entity, beneath: root, into: world, copies: &copies)
        }
        remapModelReferences(in: copies)

        let existingResources = Dictionary(uniqueKeysWithValues: world.getResources().map { (ObjectIdentifier(type(of: $0)), $0) })
        var previousResources: [PreviousResource] = []
        for resource in scene.world.getResources() {
            let type = type(of: resource)
            previousResources.append(PreviousResource(type: type, value: existingResources[ObjectIdentifier(type)]))
            world.insertResource(resource)
        }
        world.flush()
        lock.withLock {
            active = ActiveScene(source: source, root: root, previousResources: previousResources, spawnedEntityIDs: [])
            lastFailure = nil
        }
    }

    @MainActor
    private func copyHierarchy(from original: Entity, beneath parent: Entity, into world: World, copies: inout [Entity.ID: Entity]) {
        let copy = original.copy()
        copy.components[RelationshipComponent.self] = nil
        world.addEntity(copy)
        copies[original.id] = copy
        parent.addChild(copy)
        for child in original.children {
            copyHierarchy(from: child, beneath: copy, into: world, copies: &copies)
        }
    }

    @MainActor
    private func remapModelReferences(in copies: [Entity.ID: Entity]) {
        // Entity IDs belong to a world. Resolve references only after the whole
        // hierarchy has been copied, including roots visited after their owners.
        for copy in copies.values {
            if let state = copy.components[Model3DSourceState.self] {
                copy.components[Model3DSourceState.self] = Model3DSourceState(
                    reference: state.reference,
                    rootEntityID: state.rootEntityID.flatMap { copies[$0]?.id },
                    error: state.error
                )
            }
            if let node = copy.components[ModelNode3DComponent.self], let root = copies[node.modelRoot] {
                copy.components[ModelNode3DComponent.self] = ModelNode3DComponent(modelRoot: root.id, nodeIndex: node.nodeIndex)
            }
            if let skin = copy.components[SkinnedMesh3DComponent.self], let root = copies[skin.modelRoot] {
                copy.components[SkinnedMesh3DComponent.self] = skin.remapped(to: root.id)
            }
        }
    }
}

struct SceneNavigationSystem: System {
    @Res<SceneNavigator>
    private var navigator

    // Replacing a scene changes archetypes and invalidates component pointers.
    // It must finish before another system starts traversing the world.
    var queries: SystemQueries {
        SystemQueries(queries: [_navigator, ExclusiveWorldAccess()])
    }

    init(world _: World) {}

    @MainActor
    func update(context: UpdateContext) {
        navigator.applyPending(in: context.world)
    }
}
