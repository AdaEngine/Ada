@_spi(AdaEngine) import AdaEngine
@_spi(Internal) @testable import AdaRender
@_spi(Internal) import AdaUI
import Foundation
import Math
import Testing

@testable import AdaEditor

@Suite("Editor agent activity background", .serialized)
@MainActor
struct EditorAgentActivityTests {
    @Test("Only successful completion is green; cancellation stays neutral")
    func operationStates() {
        #expect(EditorAgentActivityState.resolve(operation: nil, connection: .disconnected, isSending: false) == .idle)
        #expect(EditorAgentActivityState.resolve(operation: .running, connection: .running, isSending: true) == .working)
        #expect(EditorAgentActivityState.resolve(operation: .needsAttention, connection: .running, isSending: true) == .needsInput)
        #expect(EditorAgentActivityState.resolve(operation: .completed, connection: .ready(nil), isSending: false) == .completed)
        #expect(EditorAgentActivityState.resolve(operation: .failed, connection: .ready(nil), isSending: false) == .failed)
        #expect(EditorAgentActivityState.resolve(operation: .cancelled, connection: .running, isSending: true) == .idle)
        #expect(EditorAgentActivityState.resolve(operation: nil, connection: .failed("Unavailable"), isSending: false) == .failed)
        #expect(EditorAgentActivityState.resolve(operation: .completed, connection: .connecting, isSending: false) == .working)
    }

    @Test("Other projects and notification history do not activate this window")
    func unrelatedOperations() {
        let center = EditorNotificationCenter()
        center.activities.begin(.init(source: .agent, title: "Other project", state: .needsAttention))
        let model = EditorAgentViewModel(project: nil, settings: EditorAgentSettingsStore(), notifications: center)
        #expect(model.activityState == .idle)
    }

    @Test("Semantic colors ignore custom accent and working restores it")
    func accentAndTransitions() {
        var animation = EditorAgentGlowAnimation()
        animation.configure(state: .working, accent: .purple)
        animation.advance(1 / 60, reduceMotion: true)
        #expect(animation.color == .purple)
        for state in [EditorAgentActivityState.completed, .needsInput, .failed] {
            animation.configure(state: state, accent: .blue)
            animation.advance(1 / 60, reduceMotion: true)
            #expect(animation.color == state.color(accent: .purple))
            #expect(animation.hueSpread == 0.012)
        }
        animation.configure(state: .working, accent: .blue)
        animation.advance(1 / 60, reduceMotion: true)
        #expect(animation.color == .blue)
    }

    @Test("Completion settles in green without recurring redraws; idle fades out")
    func completionAndIdle() {
        var animation = EditorAgentGlowAnimation()
        animation.configure(state: .working, accent: .blue)
        for _ in 0..<60 { animation.advance(1 / 60, reduceMotion: false) }
        let start = animation.time
        animation.configure(state: .completed, accent: .blue)
        animation.advance(1 / 60, reduceMotion: false)
        #expect(animation.color != EditorAgentActivityState.completed.color(accent: .blue))
        #expect(animation.time >= start)
        for _ in 0..<120 { animation.advance(1 / 60, reduceMotion: false) }
        #expect(animation.color == EditorAgentActivityState.completed.color(accent: .blue))
        #expect(animation.intensity > 0)
        let redrawCompleted = animation.advance(1 / 60, reduceMotion: false)
        #expect(!redrawCompleted)
        animation.configure(state: .idle, accent: .blue)
        for _ in 0..<120 { animation.advance(1 / 60, reduceMotion: false) }
        #expect(animation.intensity == 0)
        let redrawIdle = animation.advance(1 / 60, reduceMotion: false)
        #expect(!redrawIdle)
    }

    @Test("Success holds for three seconds then fades, without restarting on settings changes")
    func successTimeout() {
        var animation = EditorAgentGlowAnimation()
        animation.configure(state: .completed, accent: .blue, activityID: "first")
        animation.advance(0.3, reduceMotion: false)
        #expect(animation.visibility == 1)
        animation.advance(2.6, reduceMotion: false)
        animation.configure(state: .completed, accent: .purple, activityID: "first", opacity: 0.2)
        animation.advance(0.2, reduceMotion: false)
        #expect(animation.visibility > 0 && animation.visibility < 1)
        animation.advance(0.3, reduceMotion: false)
        #expect(!animation.isVisible)
        let redraw = animation.advance(10, reduceMotion: false)
        #expect(!redraw)
        animation.configure(state: .completed, accent: .blue, activityID: "first", enabled: false)
        animation.advance(1, reduceMotion: false)
        animation.configure(state: .completed, accent: .blue, activityID: "first", enabled: true)
        animation.advance(1, reduceMotion: false)
        #expect(!animation.isVisible)
        animation.configure(state: .completed, accent: .blue, activityID: "second")
        animation.advance(0.3, reduceMotion: false)
        #expect(animation.visibility == 1)
    }

    @Test("Toggling off fades the existing surface and toggling on fades it back in")
    func visibilityTransitions() {
        var animation = EditorAgentGlowAnimation()
        animation.configure(state: .working, accent: .blue, opacity: 0.25)
        animation.advance(0.15, reduceMotion: false)
        #expect(animation.visibility > 0 && animation.visibility < 1)
        animation.advance(0.2, reduceMotion: false)
        #expect(animation.visibility == 1)
        #expect(animation.opacity == 0.25)
        animation.configure(state: .working, accent: .blue, enabled: false, opacity: 0.25)
        animation.advance(0.15, reduceMotion: false)
        #expect(animation.isVisible)
        animation.advance(0.2, reduceMotion: false)
        #expect(!animation.isVisible)
        let redraw = animation.advance(1, reduceMotion: false)
        #expect(!redraw)
        animation.configure(state: .working, accent: .blue, enabled: true, opacity: 0.25)
        animation.advance(0.15, reduceMotion: false)
        #expect(animation.visibility > 0 && animation.visibility < 1)
    }

    @Test("Elapsed background time expires success; reduced motion and paused waves still honor the deadline")
    func backgroundDeadline() {
        for reduced in [false, true] {
            var animation = EditorAgentGlowAnimation()
            animation.configure(state: .completed, accent: .blue)
            animation.advance(0.3, reduceMotion: reduced)
            let phase = animation.time
            animation.advance(30, reduceMotion: reduced, wavesEnabled: false)
            #expect(!animation.isVisible)
            #expect(animation.time == phase)
            animation.configure(state: .needsInput, accent: .blue)
            animation.advance(30, reduceMotion: reduced, wavesEnabled: false)
            #expect(animation.isVisible)
        }
    }

    @Test("Reduce Motion keeps a static status and invalid deltas cannot poison uniforms")
    func reducedMotion() {
        var animation = EditorAgentGlowAnimation()
        animation.configure(state: .needsInput, accent: .blue)
        let time = animation.time
        animation.advance(1, reduceMotion: true)
        #expect(animation.time == time)
        let redrawStatic = animation.advance(1, reduceMotion: true)
        #expect(!redrawStatic)
        animation.advance(.nan, reduceMotion: false)
        #expect(animation.time.isFinite)
    }

    @Test("Bundled shader compiles with the AdaUI ABI")
    func shaderCompilation() throws {
        let source = try EditorAgentGlowMaterial.fragmentShader()
        let result = try ShaderCompiler(shaderSource: source.asset).compileSpirvBin(for: .fragment, ignoreCache: true)
        #expect(!result.data.isEmpty)
    }

    @Test("Raised glow uses the full window bounds and does not intercept controls")
    func overlayLayoutAndInput() throws {
        if unsafe RenderEngine.shared == nil {
            unsafe RenderEngine.configurations.preferredBackend = .headless
            RenderWorldPlugin().setup(in: AppWorlds(main: World(name: "AgentOverlayUI")))
        }
        let size = Size(width: 900, height: 600)
        let suite = "AdaEditor.GlowLayout.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let appearance = EditorAppearanceSettings(defaults: defaults)
        var tapped = false
        let container = UIContainerView(
            rootView: Button("Panel control") { tapped = true }
                .accessibilityIdentifier("GlowTest.PanelControl")
                .frame(width: size.width, height: size.height)
                .background(Color.black)
                .overlay { EditorAgentActivityOverlay(state: .working, settings: appearance) }
        )
        container.frame = Rect(origin: .zero, size: size)
        container.bounds.size = size
        container.layoutIfNeeded()
        container.update(1 / 30)
        let context = UIGraphicsContext()
        container.draw(with: context)
        let commands = context.getDrawCommands()
        guard
            case let .drawShaderEffect(_, material)? = commands.last,
            let glow = material as? CustomMaterial<EditorAgentGlowMaterial>
        else {
            Issue.record("Expected glow above panel content")
            return
        }
        #expect(glow.parameters.geometry.x == size.width)
        #expect(glow.parameters.geometry.y == size.height)
        _ = try container.uiTapNode(matching: .accessibilityIdentifier("GlowTest.PanelControl"))
        #expect(tapped)
    }
}
