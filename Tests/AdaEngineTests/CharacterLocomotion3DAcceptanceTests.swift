import AdaAnimation
@_spi(Internal) import AdaApp
import AdaAssets
import AdaECS
import AdaPhysics
@testable import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

extension CharacterLocomotion3DTests {
    @Test
    func selectsGaitsAndPreservesCyclePhaseWithMultipleFixedTicks() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        await garden.step(25)
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [0, 0, 1.65]
        await garden.step(24)
        let walk = try garden.player(on: robot)
        #expect(try garden.clip(on: robot) == "Walk")
        #expect(abs(walk.speed - 1.5) < 0.002)

        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [0, 0, 3.3]
        await garden.fixed(4)
        #expect(try garden.clip(on: robot) == "Walk")
        #expect(try garden.player(on: robot).time == walk.time)
        await garden.world.runScheduler(.postUpdate, deltaTime: 0)
        #expect(try garden.clip(on: robot) == "Run")
        let run = try garden.player(on: robot)
        let walkDuration = try #require(walk.clipIndex.map { walk.clips[$0].duration })
        let runDuration = try #require(run.clipIndex.map { run.clips[$0].duration })
        #expect(abs(run.time / runDuration - walk.time.truncatingRemainder(dividingBy: walkDuration) / walkDuration) < 0.0001)
        await garden.world.runScheduler(.postUpdate, deltaTime: 0.1)
        #expect(try garden.player(on: robot).time > run.time)

        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [0, 0, -3.3]
        await garden.step(70)
        #expect(try garden.clip(on: robot) == "Run")
        let turned = try #require(robot.components[Transform.self]?.rotation)
        #expect(abs(turned.y) > 0.99)
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = .zero
        await garden.step(22)
        #expect(try garden.clip(on: robot) == "Idle")
        let stopped = try #require(robot.components[Transform.self]?.rotation)
        #expect(abs(stopped.y) > 0.99)
    }

    @Test
    func resolvesSidewaysWallSlideAndChoosesDirectionalClipWithoutTurning() async throws {
        let garden = try await LocomotionTestGarden()
        garden.addBox(at: [1.4, 0.9, 0], size: [0.2, 2, 12])
        let robot = try garden.spawnRobot()
        let rotation = robot.components[Transform.self]?.rotation
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.facingMode = .keepFacing
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.right.walk = "Run"
        await garden.step(25)
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [1.65, 0, 0]
        await garden.step(15)
        #expect(try garden.clip(on: robot) == "Run")
        await garden.step(50)
        #expect(try garden.clip(on: robot) == "Idle")
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [1.65, 0, 1.65]
        await garden.step(16)
        let velocity = try #require(robot.components[CharacterController3DComponent.self]?.velocity)
        #expect(abs(velocity.x) < 0.04)
        #expect(velocity.z > 1)
        #expect(try garden.clip(on: robot) == "Walk")
        #expect(robot.components[Transform.self]?.rotation == rotation)
    }

    @Test
    func jumpsFallsLandsAndResumesWalkingWithAnotherRobotUnaffected() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        let witness = try garden.spawnRobot(at: [-4, 0.005, 0])
        await garden.step(25)
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [0, 0, 1.65]
        await garden.step(15)
        robot.components[CharacterController3DComponent.self]?.jumpRequested = true

        var entries: [Locomotion.Phase] = []
        for _ in 0..<90 {
            await garden.step(1)
            if let state = robot.components[CharacterLocomotion3DComponent.self]?.activeState, entries.last != state {
                entries.append(state)
            }
        }
        #expect(entries == [.jump, .fall, .land, .walk])
        #expect(try garden.clip(on: witness) == "Idle")
        #expect(try garden.player(on: robot).instanceID != garden.player(on: witness).instanceID)
    }

    @Test
    func steppingOffARealLedgeFallsAndAResetCancelsTheOldLandingHistory() async throws {
        let garden = try await LocomotionTestGarden(floor: false)
        garden.addBox(at: [0, -0.5, 0], size: [3, 1, 4])
        garden.addBox(at: [0, -4.5, 0], size: [40, 1, 40])
        let robot = try garden.spawnRobot()
        await garden.step(25)
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [2, 0, 0]
        var sawFall = false
        for _ in 0..<120 {
            await garden.step(1)
            let state = robot.components[CharacterLocomotion3DComponent.self]?.activeState
            #expect(state != .jump)
            if state == .fall { sawFall = true; break }
        }
        try #require(sawFall)
        robot.components[Transform.self]?.position = [0, 0, 0]
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = .zero
        robot.components[CharacterController3DComponent.self]?.resetMotion = true
        await garden.step(1)
        #expect(robot.components[CharacterController3DComponent.self]?.isGrounded == true)
        #expect(try garden.clip(on: robot) == "Idle")
    }

    @Test
    func invalidMappingAndOtherPlaybackWritersPreserveTheModelUntilCorrected() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.clips.walk = "Not available"
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [1.65, 0, 0]
        await garden.step(25)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.diagnostic == .missingClip("Not available"))
        #expect(try garden.clip(on: robot) == "Idle")
        #expect(robot.components[Transform.self]?.rotation == .identity)
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.clips.walk = "Walk"
        await garden.step(1)
        #expect(try garden.clip(on: robot) == "Walk")

        var manual = ModelAnimationPlayback3DComponent()
        manual.clip = "Run"
        robot.components[ModelAnimationPlayback3DComponent.self] = manual
        await garden.world.runScheduler(.postUpdate, deltaTime: 0)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.diagnostic == .playbackConflict)
        #expect(try garden.clip(on: robot) == "Run")

        robot.components[ModelAnimationPlayback3DComponent.self] = nil
        let rootID = try #require(robot.components[Model3DSourceState.self]?.rootEntityID)
        let root = try #require(garden.world.getEntityByID(rootID))
        let graph = AnimationGraph(root: "Idle", nodes: [.init(id: "Idle", clip: "Idle")])
        try root.components[ModelAnimation3DComponent.self]?.player.play(graph, transitionDuration: 0)
        await garden.step(2)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.diagnostic == .playbackConflict)
        #expect(try garden.player(on: robot).graph == graph)

        garden.world.removeEntity(rootID, recursively: true)
        let replacement = try garden.source.instantiate(garden.model, in: garden.world, under: robot)
        await garden.step(2)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.diagnostic == nil)
        #expect(robot.components[Model3DSourceState.self]?.rootEntityID == replacement.id)
        #expect(try garden.clip(on: robot) == "Walk")
    }

    @Test
    func sceneReopenPersistsConfigurationAndStartsWithFreshRuntimeState() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.facingMode = .keepFacing
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.back.walk = "Run"
        await garden.step(25)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.activeState == .idle)
        let scene = Scene(from: garden.world.copy())
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("Locomotion-\(UUID()).ascn")
        defer { try? FileManager.default.removeItem(at: file) }
        try await AssetsManager.save(scene, at: file.path)
        let reopened = try AssetsManager.loadFreshSync(Scene.self, at: file.path)
        let reopenedRobot = try #require(reopened.world.getEntityByName("GardenRobot"))
        let saved = try #require(reopenedRobot.components[CharacterLocomotion3DComponent.self])
        #expect(saved.configuration.facingMode == .keepFacing)
        #expect(saved.configuration.back.walk == "Run")
        #expect(saved.activeState == nil)
        #expect(saved.diagnostic == nil)
    }

    @Test
    func lowCeilingInterruptsJumpAndAliasedLandingRestartsTheOneShot() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        robot.components[CharacterLocomotion3DComponent.self]?.configuration.clips.land = "Fall"
        garden.addBox(at: [0, 2.35, 0], size: [3, 0.2, 3])
        await garden.step(25)
        robot.components[CharacterController3DComponent.self]?.jumpRequested = true
        await garden.step(1)
        #expect(try garden.clip(on: robot) == "Jump")
        for _ in 0..<12 {
            await garden.step(1)
            if robot.components[CharacterLocomotion3DComponent.self]?.activeState == .fall { break }
        }
        try #require(robot.components[CharacterLocomotion3DComponent.self]?.activeState == .fall)
        await garden.step(2)
        let fallTime = try garden.player(on: robot).time
        for _ in 0..<30 {
            await garden.step(1)
            if robot.components[CharacterLocomotion3DComponent.self]?.activeState == .land { break }
        }
        try #require(robot.components[CharacterLocomotion3DComponent.self]?.activeState == .land)
        #expect(try garden.clip(on: robot) == "Fall")
        #expect(try garden.player(on: robot).time < fallTime)
    }

    @Test
    func partialSceneConfigurationUsesDefaultsForOmittedFields() throws {
        let source = """
        {"configuration": {"facingMode": "keepFacing", "clips": {"walk": "Walk Forward"}, "left": {"walk": "Walk Left"}}}
        """
        let value = try JSONDecoder().decode(CharacterLocomotion3DComponent.self, from: Data(source.utf8))
        #expect(value.isEnabled)
        #expect(value.configuration.facingMode == .keepFacing)
        #expect(value.configuration.clips.walk == "Walk Forward")
        #expect(value.configuration.clips.run == "Run")
        #expect(value.configuration.left.walk == "Walk Left")
        #expect(value.configuration.left.run == nil)
        #expect(value.configuration.right == .init())
        #expect(value.configuration.landingDuration == 0.25)
    }

    @Test
    func newBindingIgnoresSkippedPhysicsAndResetsFromAnAirborneTeleport() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        await garden.step(3)
        #expect(try garden.clip(on: robot) == "Idle")

        robot.components[CharacterLocomotion3DComponent.self] = .init()
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [.nan, 0, 0]
        await garden.step(1)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.activeState == nil)

        robot.components[Transform.self]?.position = [0, 2, 0]
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = .zero
        robot.components[CharacterController3DComponent.self]?.resetMotion = true
        await garden.step(1)
        #expect(try garden.clip(on: robot) == "Fall")
        for _ in 0..<60 {
            await garden.step(1)
            if robot.components[CharacterLocomotion3DComponent.self]?.activeState == .land { break }
        }
        #expect(try garden.clip(on: robot) == "Land")
    }

    @Test
    func inactiveOwnerReleasesPlaybackAndFacingUntilItIsReactivated() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        await garden.step(3)
        #expect(try garden.clip(on: robot) == "Idle")

        robot.isActive = false
        let facing = robot.components[Transform.self]?.rotation
        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [1.65, 0, 0]
        await garden.step(16)
        #expect(robot.components[CharacterLocomotion3DComponent.self]?.activeState == nil)
        #expect(robot.components[Transform.self]?.rotation == facing)
        #expect(try garden.clip(on: robot) == "Idle")

        robot.isActive = true
        await garden.step(16)
        #expect(try garden.clip(on: robot) == "Walk")
    }

    @Test
    func stalePhysicsSamplesAndAnimationLODCannotAdvanceFixedLanding() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot(at: [0, 1, 0])
        let rootID = try #require(robot.components[Model3DSourceState.self]?.rootEntityID)
        let root = try #require(garden.world.getEntityByID(rootID))
        root.components[ModelAnimation3DComponent.self]?.evaluationLOD = .init(offscreenRate: 1)
        await garden.step(1)
        #expect(try garden.clip(on: robot) == "Fall")
        for _ in 0..<60 {
            await garden.step(1)
            if robot.components[CharacterLocomotion3DComponent.self]?.activeState == .land { break }
        }
        try #require(robot.components[CharacterLocomotion3DComponent.self]?.activeState == .land)
        let gate = try #require(garden.world.getResource(PhysicsSimulationGate3D.self))
        gate.setPending(owner: robot.id, reason: "Test pause", pending: true)
        await garden.step(24)
        #expect(try garden.clip(on: robot) == "Land")
        let held = try garden.player(on: robot)
        #expect(held.time == held.clipIndex.map { held.clips[$0].duration })
        gate.setPending(owner: robot.id, reason: "Test pause", pending: false)
        robot.components[CharacterController3DComponent.self]?.jumpRequested = true
        await garden.step(1)
        #expect(try garden.clip(on: robot) == "Jump")
    }

    @Test
    func directionalBoundariesAndGroundContactHysteresisUseResolvedSamples() {
        var motion = CharacterLocomotion3DMotion()
        var configuration = Locomotion.Configuration()
        configuration.facingMode = .keepFacing
        configuration.left.walk = "Left walk"
        configuration.right.walk = "Right walk"
        configuration.back.walk = "Back walk"
        let cases: [(angle: Float, speed: Float, grounded: Bool, clip: String)] = [
            (0, 0.15, true, "Idle"), (0, 0.2, true, "Walk"),
            (48, 1.5, true, "Walk"), (58, 1.5, true, "Right walk"),
            (42, 1.5, true, "Right walk"), (32, 1.5, true, "Walk"),
            (-90, 1.5, true, "Left walk"), (180, 1.5, true, "Back walk"),
            (180, 2.5, true, "Run"), (180, 2.2, true, "Run"), (180, 2, true, "Back walk"),
            (180, 1.5, false, "Back walk"), (180, 1.5, true, "Back walk"),
            (180, 1.5, false, "Back walk"), (180, 1.5, false, "Fall"), (180, 1.5, true, "Land")
        ]
        for sample in cases {
            let angle = sample.angle * .pi / 180
            let velocity = Vector3(Math.sin(angle) * sample.speed, 0, Math.cos(angle) * sample.speed)
            let rotation = motion.advance(
                velocity: velocity,
                grounded: sample.grounded,
                deltaTime: 1 / 60,
                rotation: .identity,
                configuration: configuration
            )
            #expect(rotation == nil)
            #expect(motion.request?.clip == sample.clip)
        }
    }

    @Test
    func diagonalSelectsClockwiseGaitWithARotatedOwner() {
        var motion = CharacterLocomotion3DMotion()
        var configuration = Locomotion.Configuration()
        configuration.facingMode = .keepFacing
        configuration.right.walk = "Right walk"
        let rotation = Quat(axis: .up, angle: .pi / 4)
        _ = motion.advance(velocity: [1, 0, 0], grounded: true, deltaTime: 1 / 60, rotation: rotation, configuration: configuration)
        #expect(motion.request?.clip == "Right walk")
    }
}
