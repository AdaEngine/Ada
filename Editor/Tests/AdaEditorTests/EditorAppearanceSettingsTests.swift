@_spi(AdaEngine) import AdaEngine
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@MainActor
@Suite("Agent glow preference", .serialized)
struct EditorAppearanceSettingsTests {
    @Test("The preference is available in General even without an open project")
    func settingsWithoutProject() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AppearanceSettingsUI")))
        }
        let model = EditorSettingsWindowViewModel(editorViewModel: nil, selectedSection: .general)
        let container = UIContainerView(rootView: EditorSettingsWindowView(viewModel: model).theme(.adaEditor))
        container.frame = Rect(x: 0, y: 0, width: 1000, height: 760)
        container.bounds.size = container.frame.size
        container.layoutIfNeeded()
        _ = try container.uiNode(matching: .accessibilityIdentifier("AdaEditor.Settings.AgentActivityGlow"))
    }

    @Test("Glow is enabled by default and the disabled choice survives reloading")
    func persistence() throws {
        let suite = "AdaEditor.GlowTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorAppearanceSettings(defaults: defaults)
        #expect(settings.agentActivityGlowEnabled)
        settings.agentActivityGlowEnabled = false
        #expect(!EditorAppearanceSettings(defaults: defaults).agentActivityGlowEnabled)
        settings.agentActivityGlowEnabled = true
        #expect(EditorAppearanceSettings(defaults: defaults).agentActivityGlowEnabled)
        settings.agentGlowRadius = 12
        settings.agentGlowOpacity = 0.2
        settings.setAccentColor(.red)
        let reloaded = EditorAppearanceSettings(defaults: defaults)
        #expect(reloaded.agentGlowRadius == 12)
        #expect(reloaded.agentGlowOpacity == 0.2)
        #expect(reloaded.accentColor(fallback: .blue) == .red)
        reloaded.useThemeAccent()
        #expect(EditorAppearanceSettings(defaults: defaults).accentColor(fallback: .blue) == .blue)
        settings.agentGlowRadius = -10
        settings.agentGlowOpacity = 10
        #expect(settings.agentGlowRadius == 4)
        #expect(settings.agentGlowOpacity == 1)
        settings.agentGlowRadius = .nan
        settings.agentGlowOpacity = .infinity
        #expect(settings.agentGlowRadius == EditorAppearanceSettings.defaultRadius)
        #expect(settings.agentGlowOpacity == EditorAppearanceSettings.defaultOpacity)
    }

    @Test("The settings control fades glow out and back in across observing windows")
    func toggleUpdatesWindows() async throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "GlowPreferenceUI")))
        }
        let suite = "AdaEditor.GlowUITests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = EditorAppearanceSettings(defaults: defaults)
        let controls = UIContainerView(rootView: EditorAgentGlowSettings(settings: settings))
        settings.agentGlowRadius = 12
        settings.agentGlowOpacity = 0.2
        settings.setAccentColor(.red)
        controls.frame = Rect(x: 0, y: 0, width: 500, height: 360)
        controls.bounds.size = controls.frame.size
        controls.layoutIfNeeded()
        let windows = (0..<2)
            .map { _ in
                let container = UIContainerView(rootView: EditorAgentActivityOverlay(state: .working, settings: settings))
                container.frame = Rect(x: 0, y: 0, width: 500, height: 300)
                container.bounds.size = container.frame.size
                return container
            }
        for enabled in [true, false, true] {
            if settings.agentActivityGlowEnabled != enabled {
                _ = try controls.uiTapNode(matching: .accessibilityIdentifier("AdaEditor.Settings.AgentActivityGlow"))
            }
            for _ in 0..<30 {
                await Task.yield()
                controls.layoutIfNeeded()
                for window in windows {
                    window.layoutIfNeeded()
                    window.update(1 / 60)
                }
            }
            for window in windows {
                let context = UIGraphicsContext()
                window.draw(with: context)
                let drawsGlow = context.getDrawCommands()
                    .contains {
                        if case .drawShaderEffect = $0 {
                            return true
                        }
                        return false
                    }
                #expect(drawsGlow == enabled)
                if enabled, case let .drawShaderEffect(_, material)? = context.getDrawCommands().last,
                    let glow = material as? CustomMaterial<EditorAgentGlowMaterial> {
                    #expect(glow.parameters.geometry.w == 12)
                    #expect(abs(glow.parameters.style.w - 0.2) < 0.001)
                    #expect(glow.parameters.color == .red)
                }
            }
            #expect(EditorAppearanceSettings(defaults: defaults).agentActivityGlowEnabled == enabled)
        }
    }
}
