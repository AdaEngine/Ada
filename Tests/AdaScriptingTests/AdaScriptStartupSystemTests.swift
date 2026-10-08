@testable import AdaScripting
import Testing

@Suite("AdaScript startup system", .serialized)
struct AdaScriptStartupSystemTests {
    private let sources = [
        AdaScriptSource(
            path: "Startup.ada",
            source: """
            @system(scheduler: "update", id: "game.update")
            class UpdateSystem {
                func update(context) {}
            }

            @system(scheduler: "startup", id: "game.bootstrap")
            class BootstrapSystem {
                func update(context) {}
            }
            """
        )
    ]

    @Test("selected startup system must exist and use the startup scheduler")
    func validatesSelectedStartupSystem() throws {
        _ = try AdaScriptPlugin(
            sources: sources,
            name: "StartupGame",
            startupSystemIdentifier: "game.bootstrap"
        )

        #expect(throws: AdaScriptError.invalidManifest(
            "Startup system 'game.missing' does not match an @system id."
        )) {
            try AdaScriptPlugin(
                sources: sources,
                name: "MissingStartupGame",
                startupSystemIdentifier: "game.missing"
            )
        }
        #expect(throws: AdaScriptError.invalidManifest(
            "Startup system 'game.update' must use scheduler: \"startup\"."
        )) {
            try AdaScriptPlugin(
                sources: sources,
                name: "InvalidStartupGame",
                startupSystemIdentifier: "game.update"
            )
        }
    }
}
