import AdaECS
import Testing

@Suite("Movie Maker simulation clock")
struct MovieMakerClockTests {
    @Test func nestedSchedulersUseMovieTimeAndExplicitPhysicsStepWins() async {
        let world = World()
        world.addScheduler(Scheduler(name: .update))
        world.addScheduler(Scheduler(name: .postUpdate))
        await SimulationClock.$fixedDeltaTime.withValue(1 / 30) {
            for _ in 0..<3 {
                await world.runScheduler(.update)
                #expect(abs((world.getResource(DeltaTime.self)?.deltaTime ?? 0) - 1 / 30) < 0.00001)
                await world.runScheduler(.postUpdate)
            }
            #expect(abs((world.getResource(ElapsedTime.self)?.elapsedTime ?? 0) - 0.1) < 0.00001)
            await world.runScheduler(.update, deltaTime: 1 / 60)
            #expect(abs((world.getResource(DeltaTime.self)?.deltaTime ?? 0) - 1 / 60) < 0.00001)
        }
        #expect(SimulationClock.fixedDeltaTime == nil)
    }
}
