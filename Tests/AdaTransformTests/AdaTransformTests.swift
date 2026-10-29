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

    @Test("Simultaneous ancestor and descendant edits preserve scaled hierarchy matrices")
    func simultaneousHierarchyEdits() async throws {
        var chain: [Entity] = []
        for index in 0..<12 {
            let entity = world.main.spawn { Transform(position: [Float(index), 1, 0]) }
            chain.last?.addChild(entity)
            chain.append(entity)
        }
        await world.main.runScheduler(.postUpdate)
        world.main.clearTrackers()
        for (index, entity) in chain.enumerated() {
            entity.components[Transform.self] = Transform(scale: index == 0 ? [-1, 2, 1] : .one,
                                                        position: [Float(index + 1), 2, -1])
        }
        await world.main.runScheduler(.postUpdate)
        var expected = Transform3D.identity
        for entity in chain {
            expected = expected * (try #require(entity.components[Transform.self])).matrix
            #expect(entity.components[GlobalTransform.self]?.matrix == expected)
        }
        // Only the leaf changes on the following tick; ancestors stay clean.
        world.main.clearTrackers()
        let leaf = try #require(chain.last)
        leaf.components[Transform.self]?.position = [40, 3, -2]
        await world.main.runScheduler(.postUpdate)
        let parent = try #require(chain.dropLast().last?.components[GlobalTransform.self])
        #expect(leaf.components[GlobalTransform.self]?.matrix == parent.matrix * (try #require(leaf.components[Transform.self])).matrix)
    }

    @Test("Transformless gaps do not suppress a dirty descendant")
    func transformlessGap() async throws {
        let root = world.main.spawn { Transform(position: [10, 0, 0]) }
        let gap = world.main.spawn()
        let leaf = world.main.spawn { Transform(position: [3, 0, 0]) }
        root.addChild(gap); gap.addChild(leaf)
        await world.main.runScheduler(.postUpdate)
        world.main.clearTrackers()
        root.components[Transform.self]?.position = [20, 0, 0]
        leaf.components[Transform.self]?.position = [7, 0, 0]
        await world.main.runScheduler(.postUpdate)
        #expect(leaf.components[GlobalTransform.self]?.getTransform().position == Vector3(7, 0, 0))
    }
}
