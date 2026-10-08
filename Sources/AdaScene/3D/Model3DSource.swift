import AdaAnimation
import AdaAssets
import AdaECS
import Foundation

/// A portable model reference that preserves imported hierarchy, materials and animation.
/// ``Model3DPlugin`` loads the asset and creates an instance beneath the owning entity.
@Component
public struct Model3DSource: Codable, Equatable, Sendable {
    public var source: String
    public var animation: String
    public var autoplay: Bool
    public var repeats: Bool
    /// Optional authored pose graph. When present it takes precedence over the single clip.
    public var animationGraph: AnimationGraph?

    public init(source: String = "", animation: String = "", autoplay: Bool = false, repeats: Bool = true, animationGraph: AnimationGraph? = nil) {
        self.source = source
        self.animation = animation
        self.autoplay = autoplay
        self.repeats = repeats
        self.animationGraph = animationGraph
    }

    /// Installs an already loaded asset. Used by hosts that prepare models before their first frame.
    /// An invalid clip fails before creating entities. Each call creates an independent animation player.
    @discardableResult
    public func instantiate(_ model: ModelAsset3D, in world: World, under owner: Entity) throws -> Entity {
        guard animationGraph != nil || animation.isEmpty || model.animationClips.contains(where: { $0.name == animation }) else {
            throw AssetError.message("Model has no animation named '\(animation)'.")
        }
        if let animationGraph {
            guard let rig = model.animationRig else { throw AssetError.message("Model has no animation rig.") }
            try animationGraph.validate(rig: rig, clips: model.animationClips)
        }
        let root = model.instantiate(in: world)
        if var animationComponent = root.components[ModelAnimation3DComponent.self], animationGraph != nil || !animation.isEmpty {
            if let animationGraph {
                try animationComponent.player.play(animationGraph, transitionDuration: 0)
            } else {
                try animationComponent.player.play(animation, transitionDuration: 0)
            }
            animationComponent.player.isPlaying = autoplay
            animationComponent.player.repeats = repeats
            root.components[ModelAnimation3DComponent.self] = animationComponent
        }
        owner.addChild(root)
        owner.components[Model3DSourceState.self] = .init(reference: self, rootEntityID: root.id)
        return root
    }
}

/// Runtime status of a model reference. Generated nodes are not part of the authored scene.
public struct Model3DSourceState: Component {
    public let reference: Model3DSource
    public let rootEntityID: Entity.ID?
    public let error: String?

    public init(reference: Model3DSource, rootEntityID: Entity.ID? = nil, error: String? = nil) {
        self.reference = reference
        self.rootEntityID = rootEntityID
        self.error = error
    }
}

/// Loads changed references asynchronously, applying hierarchy changes through deferred world commands.
@PlainSystem
public struct Model3DSourceSystem {
    @Query<Entity, Model3DSource> private var sources
    @Query<Entity, Model3DSourceState> private var instances
    @Commands private var commands

    public init(world _: World) {}

    public func update(context _: UpdateContext) async {
        var pending: [(Entity.ID, Model3DSource)] = []
        sources.forEach { entity, reference in
            let state = entity.components[Model3DSourceState.self]
            if state?.reference != reference { pending.append((entity.id, reference)) }
        }
        instances.forEach { entity, state in
            guard entity.components[Model3DSource.self] == nil else {
                return
            }
            let id = entity.id
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Model3DSource.self] == nil else {
                    return
                }
                if let rootID = state.rootEntityID { world.removeEntity(rootID, recursively: true) }
                owner.components[Model3DSourceState.self] = nil
            }
        }
        for (id, reference) in pending {
            let result: Result<ModelAsset3D?, AssetError>
            do {
                let model = reference.source.isEmpty ? nil : try await AssetsManager.load(ModelAsset3D.self, at: reference.source).asset
                result = .success(model)
            } catch {
                result = .failure(.message(error.localizedDescription))
            }
            commands.queue.push { world in
                guard let owner = world.getEntityByID(id), owner.components[Model3DSource.self] == reference,
                    owner.components[Model3DSourceState.self]?.reference != reference else { return }
                if let rootID = owner.components[Model3DSourceState.self]?.rootEntityID {
                    world.removeEntity(rootID, recursively: true)
                }
                do {
                    if let model = try result.get() {
                        try reference.instantiate(model, in: world, under: owner)
                    } else {
                        owner.components[Model3DSourceState.self] = .init(reference: reference)
                    }
                } catch {
                    owner.components[Model3DSourceState.self] = .init(reference: reference, error: error.localizedDescription)
                }
            }
        }
    }
}
