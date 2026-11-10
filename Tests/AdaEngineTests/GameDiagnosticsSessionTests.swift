@_spi(AdaEngine) @testable import AdaEngine
import Testing

@Suite("Game diagnostics")
@MainActor
struct GameDiagnosticsSessionTests {
    @Test func publishesBothMetricsFromTheSameWindow() throws {
        let session = GameDiagnosticsSession()
        for timestamp in [0, 0.25, 0.5, 0.75] {
            session.tick(at: timestamp)
            #expect(session.sample == nil)
        }
        session.tick(at: 1)
        let sample = try #require(session.sample)
        #expect(sample.framesPerSecond == 4)
        #expect(sample.millisecondsPerFrame == 250)

        // The gap between 1.25 and 2.25 is an active-game stall.
        session.tick(at: 1.25)
        #expect(session.sample == sample)
        session.tick(at: 2.25)
        let next = try #require(session.sample)
        #expect(next.framesPerSecond == 1.6)
        #expect(next.millisecondsPerFrame == 625)
    }

    @Test func invalidTicksAndPausesDoNotSkewTheNextSample() throws {
        let session = GameDiagnosticsSession()
        session.tick(at: 10)
        session.tick(at: 10)
        session.tick(at: .infinity)
        session.tick(at: 9)
        session.tick(at: 11)
        #expect(session.sample?.framesPerSecond == 1)

        session.tick(at: 12, isRunning: false)
        #expect(session.sample == nil)
        session.tick(at: 30)
        session.tick(at: 30.5)
        #expect(session.sample == nil)
        session.tick(at: 31)
        let sample = try #require(session.sample)
        #expect(sample.framesPerSecond == 2)
        #expect(sample.millisecondsPerFrame == 500)
        #expect(GameDiagnosticsSession().sample == nil)
    }
}
