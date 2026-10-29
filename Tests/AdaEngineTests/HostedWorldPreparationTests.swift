@_spi(Internal) import AdaApp
import AdaECS
import Testing

@MainActor
@Suite("Hosted world preparation")
struct HostedWorldPreparationTests {
    @Test("The host keeps updating while an embedded world is exclusively prepared")
    func hostFramesContinue() async throws {
        let host = AppWorlds(main: World())
        host.updateScheduler = .update
        host.insertResource(HostedPreparationTicks())
        host.addSystem(HostedPreparationTickSystem.self)
        let preview = AppWorlds(main: World())
        preview.updateScheduler = .update
        preview.insertResource(HostedPreparationTicks())
        preview.addSystem(HostedPreparationTickSystem.self)
        host.addSubworld(preview, by: AppWorldName(rawValue: "PreparingPreview"))
        try await host.build()
        try await preview.withHostedUpdatesSuspended {
            for _ in 0..<3 {
                try await host.update()
                await Task.yield()
            }
            #expect(host.main.getResource(HostedPreparationTicks.self)?.value == 3)
            #expect(preview.main.getResource(HostedPreparationTicks.self)?.value == 0)
        }
        try await host.update()
        #expect(preview.main.getResource(HostedPreparationTicks.self)?.value == 1)
        do {
            try await preview.withHostedUpdatesSuspended { throw PreparationError.expected }
        } catch PreparationError.expected { }
        try await host.update()
        #expect(preview.main.getResource(HostedPreparationTicks.self)?.value == 2)
    }

    private enum PreparationError: Error { case expected }
}

private struct HostedPreparationTicks: Resource { var value = 0 }

@PlainSystem
struct HostedPreparationTickSystem {
    @ResMut<HostedPreparationTicks> private var count
    init(world _: World) {}
    func update(context _: UpdateContext) { count.value += 1 }
}
