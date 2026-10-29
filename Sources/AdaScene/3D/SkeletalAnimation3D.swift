import AdaAnimation
import AdaAssets
import AdaCorePipelines
import AdaECS
@_spi(Internal) import AdaRender
import AdaTransform
import AdaUtils
import Foundation
import Math

/// A graph marker crossed by a model's playback clock. Receive with `Events<ModelAnimation3DEvent>`.
public struct ModelAnimation3DEvent: Event, Sendable {
    public let modelRoot: Entity.ID
    public let animation: AnimationGraphEvent

    public init(modelRoot: Entity.ID, animation: AnimationGraphEvent) {
        self.modelRoot = modelRoot
        self.animation = animation
    }
}

/// Instance-local pose and named clip playback on the model root entity.
public struct ModelAnimation3DComponent: Component {
    public var player: SkeletalAnimationPlayer
    public var evaluationLOD: AnimationLOD3DSettings?
    var lodState = AnimationLOD3DState()
    var appliedGeneration: UInt64?
    var appliedPlayer: UUID?

    var canSkipUpdate: Bool {
        evaluationLOD == nil && !player.isPlaying && !player.hasPendingGraphEvents
            && appliedPlayer == player.instanceID && appliedGeneration == player.poseGeneration
    }

    public init(player: SkeletalAnimationPlayer) { self.player = player }
}

/// Associates an instantiated node with its model's animation player.
public struct ModelNode3DComponent: Component {
    public let modelRoot: Entity.ID
    public let nodeIndex: Int

    public init(modelRoot: Entity.ID, nodeIndex: Int) {
        self.modelRoot = modelRoot
        self.nodeIndex = nodeIndex
    }
}

/// A mesh instance's skin binding and model-local joint palette.
public struct SkinnedMesh3DComponent: Component {
    public let modelRoot: Entity.ID
    public let meshNodeIndex: Int
    public let skin: GLTFImportResult.Skin
    public private(set) var matrices: [Transform3D]
    public private(set) var poseGeneration: UInt64 = 0
    public let paletteID = UUID()

    public init(modelRoot: Entity.ID, meshNodeIndex: Int, skin: GLTFImportResult.Skin) {
        self.modelRoot = modelRoot
        self.meshNodeIndex = meshNodeIndex
        self.skin = skin
        self.matrices = Array(repeating: .identity, count: skin.joints.count)
    }

    /// Keeps the copied pose while giving the destination mesh its own palette identity.
    func remapped(to modelRoot: Entity.ID) -> Self {
        var copy = Self(modelRoot: modelRoot, meshNodeIndex: meshNodeIndex, skin: skin)
        copy.matrices = matrices
        copy.poseGeneration = poseGeneration
        return copy
    }

    public mutating func updateMatrices(using player: SkeletalAnimationPlayer) {
        guard player.globalTransforms.indices.contains(meshNodeIndex),
            skin.inverseBindMatrices.count == skin.joints.count,
            skin.joints.allSatisfy({ player.globalTransforms.indices.contains($0) })
        else {
            return
        }
        let meshGlobal = player.globalTransforms[meshNodeIndex]
        guard abs(meshGlobal.determinant) > 0.000001 else {
            return
        }
        let inverseMesh = meshGlobal.inverse
        for index in skin.joints.indices {
            matrices[index] = inverseMesh * player.globalTransforms[skin.joints[index]] * skin.inverseBindMatrices[index]
        }
        poseGeneration &+= 1
    }
}

/// Evaluates poses before transform propagation so extraction and shadows observe the same frame.
@PlainSystem(dependencies: [.before(TransformSystem.self)])
public struct SkeletalAnimation3DSystem {
    @Query<Entity, Ref<ModelAnimation3DComponent>> private var models
    @Query<ModelNode3DComponent, Ref<Transform>> private var nodes
    @Query<Ref<SkinnedMesh3DComponent>> private var skins
    @Query<ModelNode3DComponent, Ref<MorphWeights3DComponent>> private var morphNodes
    @Res<DeltaTime> private var time
    @EventsSender<ModelAnimation3DEvent> private var animationEvents
    @Query<Camera, CameraRenderGraph> private var cameras
    @Query<GlobalTransform> private var transformAccess

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        _ = transformAccess.wrappedValue
        var observers: [AnimationLOD3DObserver] = []
        cameras.batched().forEach { camera, graph in
            if camera.isActive, graph.subgraphLabel == .main3D {
                observers.append(.init(camera: camera))
            }
        }
        var pendingPoses: [Entity.ID: SkeletalAnimationPlayer] = [:]
        models.batched().forEach { root, animation in
            // Reading this predicate borrows the component. Avoid copying all of a
            // paused player's pose/clip arrays and marking it changed every frame.
            guard !animation.wrappedValue.canSkipUpdate else { return }
            var value = animation.wrappedValue
            if value.appliedPlayer != value.player.instanceID { value.lodState = AnimationLOD3DState() }
            if let settings = value.evaluationLOD {
                value.lodState.advance(
                    player: &value.player,
                    delta: Double(time.deltaTime),
                    settings: settings,
                    transform: root.components[GlobalTransform.self]?.matrix ?? .identity,
                    observers: observers
                )
            } else {
                value.player.advance(by: Double(time.deltaTime))
            }
            for event in value.player.drainGraphEvents() {
                animationEvents.send(ModelAnimation3DEvent(modelRoot: root.id, animation: event))
            }
            if value.appliedPlayer != value.player.instanceID || value.appliedGeneration != value.player.poseGeneration {
                pendingPoses[root.id] = value.player
                value.appliedGeneration = value.player.poseGeneration
                value.appliedPlayer = value.player.instanceID
            }
            animation.wrappedValue = value
        }
        guard !pendingPoses.isEmpty else { return }
        // Process node columns directly; static and paused model hierarchies need no grouping or pose writes.
        nodes.batched().forEach { binding, transform in
            guard let player = pendingPoses[binding.modelRoot], player.poses.indices.contains(binding.nodeIndex),
                player.rig.nodes[binding.nodeIndex].restPose != nil else { return }
            let pose = player.poses[binding.nodeIndex]
            let next = Transform(rotation: pose.rotation, scale: pose.scale, position: pose.translation)
            if transform.wrappedValue != next { transform.wrappedValue = next }
        }
        morphNodes.batched().forEach { binding, component in
            guard let player = pendingPoses[binding.modelRoot], player.morphWeights.indices.contains(binding.nodeIndex),
                player.animatedMorphNodes.contains(binding.nodeIndex) else { return }
            let weights = player.morphWeights[binding.nodeIndex]
            // Preserve authored weights on nodes that no clip animates.
            if !weights.isEmpty, component.wrappedValue.weights.count == weights.count, component.wrappedValue.weights != weights {
                component.wrappedValue.weights = weights
            }
        }
        skins.batched().forEach { skin in
            if let player = pendingPoses[skin.wrappedValue.modelRoot] { skin.wrappedValue.updateMatrices(using: player) }
        }
    }
}
