//
//  ShedulersTests.swift
//  AdaEngine
//
//  Created by Vladislav Prusakov on 06.11.2025.
//

import AdaECS
import Testing

@Suite
struct SchedulersTests {
    @Test("Explicit simulation steps set the real system delta and advance elapsed time")
    func deterministicClock() async throws {
        let world = World()
        world.insertResource(SchedulerClockProbe())
        world.addSystem(recordClockSystem.self, on: .test)
        await world.runScheduler(.test, deltaTime: 0.25)
        await world.runScheduler(.test, deltaTime: 0.125)
        await world.runScheduler(.test, deltaTime: -1)
        let probe = try #require(world.getResource(SchedulerClockProbe.self))
        #expect(probe.deltas == [0.25, 0.125, 0])
        #expect(probe.elapsed == [0.25, 0.375, 0.375])
    }

    @Test
    func `default scheduler uses multi threaded executor on supported platforms`() {
        let scheduler = Scheduler(name: .test)
        #expect(scheduler.graphExecutor is MultiThreadedSystemsGraphExecutor)
    }

    @Test
    func `scheduler keeps explicitly provided executor`() {
        let scheduler = Scheduler(name: .test, graphExecutor: SingleThreadedSystemsGraphExecutor())
        #expect(scheduler.graphExecutor is SingleThreadedSystemsGraphExecutor)
    }

    @Test
    func `add system to existing schedule`() async throws {
        let world = World()
        world.addScheduler(.init(name: .test))
        world.insertResource(CheckSystemMarker(value: 0))
        world.addSystem(checkSystem.self, on: .test)

        await world.runScheduler(.test)

        let marker = try #require(world.getResource(CheckSystemMarker.self))
        #expect(marker.value == 1, "CheckSystem should exists for Tests scheduler")
    }

    @Test
    func `add system to non existing schedule`() async throws {
        let world = World()
        
        world.insertResource(CheckSystemMarker(value: 0))
        world.addSystem(checkSystem.self, on: .test)

        await world.runScheduler(.test)

        let marker = try #require(world.getResource(CheckSystemMarker.self))
        #expect(marker.value == 1, "CheckSystem should exists for Tests scheduler")
    }
}

struct SchedulerClockProbe: Resource {
    var deltas: [Float] = []
    var elapsed: [Float] = []
}

@System
func recordClock(_ probe: ResMut<SchedulerClockProbe>, _ delta: Res<DeltaTime>, _ elapsed: Res<ElapsedTime>) {
    probe.deltas.append(delta.deltaTime)
    probe.elapsed.append(elapsed.elapsedTime)
}

struct CheckSystemMarker: Resource {
    var value: Int
}

@System
func check(_ res: ResMut<CheckSystemMarker>) {
    res.value += 1
    print(res.wrappedValue)
}

private extension SchedulerName {
    static let test: SchedulerName = "Tests"
}
