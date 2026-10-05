import AdaEngine
@testable import SkeletalGarden
import Testing

@Suite
@MainActor
struct GardenCharacterAnimationTests {
    @Test
    func controlledRobotKeepsFullRateWhileBackgroundActorsUseAnimationLOD() throws {
        let pose = SkeletalJointPose()
        let rig = try SkeletalRig(nodes: [.init(parentIndex: nil, restPose: pose, restMatrix: pose.matrix)])
        let player = try SkeletalAnimationPlayer(rig: rig, clips: [])
        let world = World()
        let controlled = world.spawn {
            GardenPlayer()
            ModelAnimation3DComponent(player: player)
        }
        let background = world.spawn { ModelAnimation3DComponent(player: player) }
        let model = ModelAsset3D(nodes: [], meshes: [], materials: [], scenes: [[]], defaultScene: 0)
        installGardenCharacterLOD(root: controlled, model: model, alternatives: [], world: world)
        installGardenCharacterLOD(root: background, model: model, alternatives: [], world: world)
        #expect(controlled.components[ModelAnimation3DComponent.self]?.evaluationLOD == nil)
        #expect(background.components[ModelAnimation3DComponent.self]?.evaluationLOD != nil)
    }
}
