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
    @Res<DeltaTime> private var time
    @EventsSender<ModelAnimation3DEvent> private var animationEvents
    @Query<Camera, CameraRenderGraph> private var cameras
    @Query<GlobalTransform> private var transformAccess

    public init(world _: World) {}

    public func update(context _: UpdateContext) {
        _ = transformAccess.wrappedValue
        var observers: [AnimationLOD3DObserver] = []
        cameras.forEach { camera, graph in
            if camera.isActive, graph.subgraphLabel == .main3D {
                observers.append(.init(camera: camera))
            }
        }
        // These references are local to this update; no structural world mutations occur here.
        var nodesByRoot: [Entity.ID: [(Int, Ref<Transform>)]] = [:]
        nodes.forEach { binding, transform in nodesByRoot[binding.modelRoot, default: []].append((binding.nodeIndex, transform)) }
        var skinsByRoot: [Entity.ID: [Ref<SkinnedMesh3DComponent>]] = [:]
        skins.forEach { skin in skinsByRoot[skin.wrappedValue.modelRoot, default: []].append(skin) }
        models.forEach { root, animation in
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
                for (index, transform) in nodesByRoot[root.id] ?? [] {
                    guard value.player.poses.indices.contains(index), value.player.rig.nodes[index].restPose != nil else { continue }
                    let pose = value.player.poses[index]
                    let next = Transform(rotation: pose.rotation, scale: pose.scale, position: pose.translation)
                    if transform.wrappedValue != next { transform.wrappedValue = next }
                }
                for skin in skinsByRoot[root.id] ?? [] { skin.wrappedValue.updateMatrices(using: value.player) }
                value.appliedGeneration = value.player.poseGeneration
                value.appliedPlayer = value.player.instanceID
            }
            animation.wrappedValue = value
        }
    }
}
