import AdaAnimation
import AdaAssets
import AdaECS
import AdaTransform
import Math

/// Instance-local pose and named clip playback on the model root entity.
public struct ModelAnimation3DComponent: Component {
    public var player: SkeletalAnimationPlayer

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

    public init(modelRoot: Entity.ID, meshNodeIndex: Int, skin: GLTFImportResult.Skin) {
        self.modelRoot = modelRoot
        self.meshNodeIndex = meshNodeIndex
        self.skin = skin
        self.matrices = Array(repeating: .identity, count: skin.joints.count)
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
    }
}

/// Evaluates poses before transform propagation so extraction and shadows observe the same frame.
@PlainSystem(dependencies: [.before(TransformSystem.self)])
public struct SkeletalAnimation3DSystem {
    @Query<Entity, Ref<ModelAnimation3DComponent>> private var models
    @Query<ModelNode3DComponent, Ref<Transform>> private var nodes
    @Query<Ref<SkinnedMesh3DComponent>> private var skins
    @Res<DeltaTime> private var time

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        models.forEach { root, animation in
            animation.player.advance(by: Double(time.deltaTime))
            nodes.forEach { binding, transform in
                guard binding.modelRoot == root.id,
                    animation.player.poses.indices.contains(binding.nodeIndex),
                    animation.player.rig.nodes[binding.nodeIndex].restPose != nil
                else {
                    return
                }
                let pose = animation.player.poses[binding.nodeIndex]
                transform.wrappedValue = Transform(rotation: pose.rotation, scale: pose.scale, position: pose.translation)
            }
            skins.forEach { binding in
                guard binding.wrappedValue.modelRoot == root.id else {
                    return
                }
                binding.wrappedValue.updateMatrices(using: animation.player)
            }
        }
    }
}
