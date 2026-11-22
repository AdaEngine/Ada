import AdaAnimation
@_spi(Internal) import AdaApp
import AdaAssets
import AdaECS
import AdaPhysics
@_spi(Internal) @testable import AdaRender
import AdaScene
import AdaTransform
import Foundation
import Math
import Testing

@MainActor
@Suite(.serialized)
struct CharacterLocomotion3DTests {
    @Test
    func gardenRobotPlaysWalkFromResolvedMovement() async throws {
        let garden = try await LocomotionTestGarden()
        let robot = try garden.spawnRobot()
        await garden.step(3)
        #expect(try garden.clip(on: robot) == "Idle")

        robot.components[CharacterController3DComponent.self]?.desiredVelocity = [1.65, 0, 0]
        await garden.step(16)

        let controller = try #require(robot.components[CharacterController3DComponent.self])
        #expect(controller.isGrounded && controller.velocity.x > 1)
        #expect(try garden.clip(on: robot) == "Walk", "GardenRobot walks when the resolved horizontal speed rises")
        let rotation = try #require(robot.components[Transform.self]?.rotation)
        #expect(rotation.y > 0.6, "GardenRobot faces the resolved direction")
    }
}

@MainActor
struct LocomotionTestGarden {
    let world = World()
    let model: ModelAsset3D
    let source: Model3DSource

    init(floor: Bool = true) async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            try RenderEngine.setupRenderEngine()
        }
        GLTFLoaderResolver.shared.setLoader(NativeGLTFLoader())
        let path = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/SkeletalGardenAssets/GardenRobot.glb").path
        model = try #require(AssetsManager.loadSync(ModelAsset3D.self, at: path).asset)
        source = Model3DSource(source: path, animation: "Idle", autoplay: true)
        let app = AppWorlds(main: world)
        app.addPlugin(MainSchedulerPlugin()).addPlugin(TransformPlugin()).addPlugin(Physics3DPlugin()).addPlugin(Model3DPlugin())
        try await app.build()
        world.insertResource(FixedTime(deltaTime: 1 / 60))
        if floor { addBox(at: [0, -0.5, 0], size: [40, 1, 40]) }
    }

    func spawnRobot(at position: Vector3 = [0, 0.005, 0]) throws -> Entity {
        let owner = world.spawn("GardenRobot") {
            Transform(position: position)
            CharacterController3DComponent()
            source
        }
        if let configuration = RuntimeTypeRegistry.makeDefaultComponent(named: "CharacterLocomotion3DComponent") {
            owner.components.insert(configuration)
        }
        try source.instantiate(model, in: world, under: owner)
        return owner
    }

    func addBox(at position: Vector3, size: Vector3) {
        world.spawn {
            Transform(position: position)
            PhysicsBody3DComponent(shapes: [.generateBox(width: size.x, height: size.y, depth: size.z)], mode: .static)
        }
    }

    func player(on owner: Entity) throws -> SkeletalAnimationPlayer {
        let id = try #require(owner.components[Model3DSourceState.self]?.rootEntityID)
        return try #require(world.getEntityByID(id)?.components[ModelAnimation3DComponent.self]?.player)
    }

    func clip(on owner: Entity) throws -> String? {
        let player = try player(on: owner)
        return player.clipIndex.map { player.clips[$0].name }
    }

    func fixed(_ count: Int = 1) async {
        await world.runScheduler(.physicsSync)
        for _ in 0..<count {
            await world.runScheduler(.physicsStep)
            await world.runScheduler(.physicsWriteback)
            await world.runScheduler(.fixedPostUpdate)
        }
    }

    func step(_ count: Int) async {
        for _ in 0..<count {
            await fixed()
            await world.runScheduler(.postUpdate, deltaTime: 1 / 60)
        }
    }
}
