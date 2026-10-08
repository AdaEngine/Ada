import Testing
import AdaECS
import Math
@testable import AdaApp
@testable import AdaTransform

@Suite("AdaTransform Tests")
@MainActor
struct AdaTransformTests: Sendable {

    let world: AppWorlds

    init() async throws {
        self.world = AppWorlds(main: World())
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(TransformPlugin())

        try await self.world.build()
    }

    @Test("Global transform test")
    func globalTransformTest() async throws {
        let entity = world.main.spawn {
            Transform()
        }
        await world.main.runScheduler(.postUpdate)

        let globalTransform = try #require(entity.components[GlobalTransform.self])
        #expect(globalTransform.matrix == Transform3D.identity)
    }

    @Test("Parent-child transform propagation test")
    func parentChildTransformPropagationTest() async throws {
        let parent = world.main.spawn {
            Transform(position: Vector3(x: 10, y: 20, z: 30))
        }
        let child = world.main.spawn {
            Transform(position: Vector3(x: 5, y: 0, z: 0))
        }
        parent.addChild(child)
        await world.main.runScheduler(.postUpdate)

        let childGlobalTransform = try #require(child.components[GlobalTransform.self])
        let expectedChildGlobalPosition = Vector3(x: 15, y: 20, z: 30)  // parent position + child local position

        #expect(childGlobalTransform.getTransform().position == expectedChildGlobalPosition)

        // Test moving parent
        parent.components[Transform.self]?.position = Vector3(x: 100, y: 200, z: 300)
        await world.main.runScheduler(.postUpdate)

        let updatedChildGlobalTransform = try #require(child.components[GlobalTransform.self])
        let expectedUpdatedChildGlobalPosition = Vector3(x: 105, y: 200, z: 300)  // new parent position + child local position

        #expect(updatedChildGlobalTransform.getTransform().position == expectedUpdatedChildGlobalPosition)
    }

    @Test("Child transform propagation with unchanged parent")
    func childTransformPropagationWithUnchangedParent() async throws {
        let parent = world.main.spawn {
            Transform(position: Vector3(x: 10, y: 20, z: 30))
        }
        let child = world.main.spawn {
            Transform(position: Vector3(x: 5, y: 0, z: 0))
        }
        parent.addChild(child)
        await world.main.runScheduler(.postUpdate)
        world.main.clearTrackers()

        child.components[Transform.self]?.position = Vector3(x: 7, y: 8, z: 9)
        await world.main.runScheduler(.postUpdate)

        let globalTransform = try #require(child.components[GlobalTransform.self])
        #expect(globalTransform.getTransform().position == Vector3(x: 17, y: 28, z: 39))
    }
}
