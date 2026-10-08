//
//  Physics3DTests.swift
//  AdaEngine
//
//  Created by Codex on 7/6/26.
//

import AdaECS
@_spi(Internal) @testable import AdaApp
@testable import AdaPhysics
import AdaTransform
import Testing

@MainActor
@Suite(.serialized)
struct Physics3DTests {

    let world: AppWorlds

    init() async throws {
        let world = AppWorlds(main: World())
        self.world = world

        world
            .addPlugin(MainSchedulerPlugin())
            .addPlugin(Physics3DPlugin())
            .addPlugin(TransformPlugin())
        try await world.build()
    }

    @Test
    func dynamicBodyFallsUnderGravity() async throws {
        let box = world.main.spawn {
            PhysicsBody3DComponent(
                shapes: [Shape3DResource.generateBox(width: 1, height: 1, depth: 1)],
                mass: 1,
                mode: .dynamic
            )
            Transform(position: [0, 4, 0])
        }

        await world.main.runScheduler(.physicsSync)

        let runtimeBody = try #require(box.components[PhysicsBody3DComponent.self]?.runtimeBody)
        let startY = try #require(box.components[Transform.self]?.position.y)
        let physicsWorld = try #require(world.main.physicsWorld3D)

        for _ in 0..<60 {
            physicsWorld.updateSimulation(1.0 / 60.0)
        }
        await world.main.runScheduler(.physicsWriteback)

        let endY = try #require(box.components[Transform.self]?.position.y)

        #expect(runtimeBody.getPosition().y < startY)
        #expect(endY < startY)
    }

    @Test
    func box3DUsesRecommendedThreadingByDefault() {
        let threading = PhysicsSimulationThreading(workerCount: 4)
        let clamped = PhysicsSimulationThreading(workerCount: 4, box3DWorkerCount: 0)

        #expect(threading.box3DWorkerCount == 4)
        #expect(clamped.box3DWorkerCount == 1)
    }

    @Test
    func physicsWorldNormalizesAndExposesSolverConfiguration() {
        let physicsWorld = PhysicsWorld3D(workerCount: 2, subStepCount: 0)

        #expect(physicsWorld.workerCount == 2)
        #expect(physicsWorld.subStepCount == 1)

        physicsWorld.subStepCount = 2
        #expect(physicsWorld.subStepCount == 2)
    }

    @Test
    func nativePerformanceProfileReportsStepPhasesAndCounters() throws {
        let metrics = PhysicsPerformanceMetrics()
        let physicsWorld = PhysicsWorld3D()

        physicsWorld.updateSimulation(1.0 / 60.0)
        physicsWorld.recordPerformance(into: metrics)

        let snapshot = try #require(metrics.snapshots.first { $0.dimension == .threeD })
        #expect(snapshot.stepCount == 1)
        #expect(snapshot.step != nil)
        #expect(snapshot.phases.contains { $0.phase == .collide })
        #expect(snapshot.phases.contains { $0.phase == .solve })
        #expect(snapshot.counters.bodyCount == 0)
    }

    @Test
    func fixedSchedulerAdvancesAndWritesBackDynamicBody() async throws {
        let box = world.main.spawn {
            PhysicsBody3DComponent(
                shapes: [Shape3DResource.generateBox(width: 1, height: 1, depth: 1)],
                mass: 1,
                mode: .dynamic
            )
            Transform(position: [0, 4, 0])
        }
        let startY = try #require(box.components[Transform.self]?.position.y)

        try await world.update()
        try await Task.sleep(for: .milliseconds(20))
        try await world.update()

        let runtimeBody = try #require(box.components[PhysicsBody3DComponent.self]?.runtimeBody)
        let endY = try #require(box.components[Transform.self]?.position.y)
        let globalEndY = try #require(box.components[GlobalTransform.self]?.getTransform().position.y)

        #expect(runtimeBody.getPosition().y < startY)
        #expect(endY < startY)
        #expect(globalEndY == endY)
    }
}
