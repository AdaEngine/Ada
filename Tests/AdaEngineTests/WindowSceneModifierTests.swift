import AdaECS
import Math
import Testing
@_spi(Internal) @testable import AdaApp

@MainActor
struct WindowSceneModifierTests {
    @Test
    func trafficLightOffsetSurvivesTitleBarModifierOrder() {
        let scene = EmptyScene()
            .windowTitleBar(.overlay)
            .windowTrafficLightOffset(x: 24, y: 8)
        let settings = makeWindowSettings(from: scene)

        #expect(settings.titleBar == WindowTitleBar(
            background: .transparent,
            reservesSafeArea: false,
            dragRegionHeight: 52,
            trafficLightOffset: Point(x: 24, y: 8)
        ))
    }

    @Test
    func windowResizableModifierUpdatesSettings() {
        let settings = makeWindowSettings(from: EmptyScene().windowResizable(false))

        #expect(settings.isResizable == false)
    }

    @Test
    func titleBarSurvivesTrafficLightOffsetModifierOrder() {
        let scene = EmptyScene()
            .windowTrafficLightOffset(x: 24, y: 8)
            .windowTitleBar(.overlay)
        let settings = makeWindowSettings(from: scene)

        #expect(settings.titleBar == WindowTitleBar(
            background: .transparent,
            reservesSafeArea: false,
            dragRegionHeight: 52,
            trafficLightOffset: Point(x: 24, y: 8)
        ))
    }

    private func makeWindowSettings<Scene: AppScene>(from scene: Scene) -> WindowSettings {
        let appWorlds = AppWorlds(main: World())
        appWorlds.insertResource(WindowSettings())

        _ = Scene._makeView(
            _AppSceneNode(value: scene),
            inputs: _SceneInputs(appWorlds: appWorlds)
        )

        return appWorlds.getResource(WindowSettings.self) ?? WindowSettings()
    }
}

private struct EmptyScene: AppScene {
    var body: Never {
        fatalError("EmptyScene has no body.")
    }
}
