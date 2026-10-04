@_spi(Internal) @testable import AdaApp
import AdaECS
import AdaPhysics
import AdaTransform
import Math
import Testing

@MainActor
@Suite
struct FixedPhysicsCatchUpTests {
    @Test
    func thirtyAndSixtyFPSAdvanceTheSameSimulationDistance() async throws {
        let slower = try await travel(frames: 30, deltaTime: 1 / 30)
        let faster = try await travel(frames: 60, deltaTime: 1 / 60)
        #expect(abs(slower - 2) < 0.001)
        #expect(abs(faster - slower) < 0.001)
    }

    @Test
    func catchUpAfterAStallIsBoundedToEightTicks() async throws {
        let distance = try await travel(frames: 1, deltaTime: 0.5)
        #expect(abs(distance - 2 * 8 / 60) < 0.001)
    }

    private func travel(frames: Int, deltaTime: Float) async throws -> Float {
        let app = AppWorlds(main: World())
        app.addPlugin(MainSchedulerPlugin()).addPlugin(Physics3DPlugin(gravity: .zero)).addPlugin(TransformPlugin())
        app.insertResource(FixedTickTime())
        try await app.build()
        app.addSystem(RecordFixedTickSystem.self, on: .fixedUpdate)
        var controller = CharacterController3DComponent()
        controller.acceleration = 10_000
        controller.desiredVelocity = [2, 0, 0]
        let character = app.main.spawn {
            controller
            Transform()
        }
        for _ in 0..<frames { await app.main.runScheduler(.fixed, deltaTime: deltaTime) }
        let tickTime = try #require(app.main.getResource(FixedTickTime.self))
        let expectedTime: Float = frames == 1 ? 8 / 60 : 1
        #expect(abs(tickTime.elapsed - expectedTime) < 0.001)
        return try #require(character.components[Transform.self]).position.x
    }
}

private struct FixedTickTime: Resource { var elapsed: Float = 0 }

@PlainSystem
struct RecordFixedTickSystem {
    @ResMut<FixedTickTime> private var tickTime
    @Res<DeltaTime> private var time

    init(world _: World) {}

    func update(context _: UpdateContext) { tickTime.elapsed += time.deltaTime }
}
