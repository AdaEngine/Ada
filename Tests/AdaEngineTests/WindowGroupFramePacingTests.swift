import AdaECS
import Foundation
import Testing
@testable import AdaEngine

@MainActor
struct WindowGroupFramePacingTests {
    @Test
    func windowGroupInstallsFramePacing() {
        let appWorlds = AppWorlds(main: World())

        WindowGroupPlugin(content: EmptyView()).setup(in: appWorlds)

        #expect(appWorlds.getResource(ApplicationFramePacing.self)?.maximumFramesPerSecond == 60)
        #expect(appWorlds.getResource(ApplicationFramePacing.self)?.synchronizesWithDisplayRefreshRate == true)
    }

    @Test
    func windowGroupKeepsExistingFramePacing() {
        let appWorlds = AppWorlds(main: World())
        appWorlds.insertResource(ApplicationFramePacing(maximumFramesPerSecond: 30))

        WindowGroupPlugin(content: EmptyView()).setup(in: appWorlds)

        #expect(appWorlds.getResource(ApplicationFramePacing.self)?.maximumFramesPerSecond == 30)
        #expect(appWorlds.getResource(ApplicationFramePacing.self)?.synchronizesWithDisplayRefreshRate == false)
    }

    @Test
    func displaySynchronizedPacingUsesDisplayMaximum() {
        let framePacing = ApplicationFramePacing.displaySynchronized()

        #expect(framePacing.resolvedMaximumFramesPerSecond(forDisplayMaximumFramesPerSecond: 120) == 120)
        #expect(framePacing.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 120) == 30...120)
    }

    @Test
    func explicitPacingRespectsConfiguredAndDisplayLimits() {
        let framePacing = ApplicationFramePacing(maximumFramesPerSecond: 60)

        #expect(framePacing.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 120) == 30...60)
        #expect(framePacing.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 24) == 24...24)
    }

    @Test
    func legacyFramePacingPayloadKeepsFixedRateBehavior() throws {
        let data = try #require(#"{"maximumFramesPerSecond":30}"#.data(using: .utf8))
        let framePacing = try JSONDecoder().decode(ApplicationFramePacing.self, from: data)

        #expect(framePacing.maximumFramesPerSecond == 30)
        #expect(framePacing.synchronizesWithDisplayRefreshRate == false)
        #expect(framePacing.minimumFramesPerSecond == nil)
    }

    @Test
    func requested120HzKeepsTheDisplayLimitAndSurvivesWindowGroupSetup() {
        let appWorlds = AppWorlds(main: World())
        let pacing = ApplicationFramePacing(maximumFramesPerSecond: 120, minimumFramesPerSecond: 120)
        appWorlds.insertResource(pacing)
        WindowGroupPlugin(content: EmptyView()).setup(in: appWorlds)
        let installed = appWorlds.getResource(ApplicationFramePacing.self)
        #expect(installed?.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 120) == 120...120)
        #expect(installed?.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 60) == 60...60)
        #expect(installed?.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 240) == 120...120)
    }

    @Test
    func minimumFrameRateRoundTripsAndClampsInvalidValues() throws {
        let pacing = ApplicationFramePacing(maximumFramesPerSecond: 120, minimumFramesPerSecond: 120)
        let decoded = try JSONDecoder().decode(ApplicationFramePacing.self, from: JSONEncoder().encode(pacing))
        #expect(decoded.minimumFramesPerSecond == 120)
        #expect(decoded.resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 120) == 120...120)
        #expect(ApplicationFramePacing(maximumFramesPerSecond: 60, minimumFramesPerSecond: 0)
            .resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 120) == 1...60)
        #expect(ApplicationFramePacing(maximumFramesPerSecond: 60, minimumFramesPerSecond: 240)
            .resolvedFrameRateRange(forDisplayMaximumFramesPerSecond: 120) == 60...60)
    }
}
