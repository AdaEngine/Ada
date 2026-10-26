import AdaApp
import AdaECS
import AdaInput
@testable import AdaScripting
import Testing

@MainActor
struct MouseCaptureBridgeTests {
    @Test func scriptsReadTransientCaptureStateThroughTheRealQueryBridge() async throws {
        MouseCaptureComponent.registerComponent()
        let world = World()
        let entity = world.spawn { MouseCaptureComponent() }
        let plugin = try AdaScriptPlugin(source: """
        @system(id: "capture-read")
        class CaptureRead {
            @query(MouseCaptureComponent) var pointers;
            func update(context) {
                for (var row in pointers) {
                    if (!row.mouseCaptureComponent.isCaptured) row.mouseCaptureComponent.isRequested = true;
                }
            }
        }
        """, name: "CaptureRead")
        plugin.setup(in: AppWorlds(main: world))
        await world.runScheduler(.update)
        #expect(try #require(entity.components[MouseCaptureComponent.self]).isRequested)
        #expect(plugin.diagnostics.isEmpty)
    }
}
