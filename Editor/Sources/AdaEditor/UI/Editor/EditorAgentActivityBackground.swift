@_spi(AdaEngine) import AdaEngine
import AdaUI
import Foundation
import Math

#if os(macOS)
    import AppKit
#elseif canImport(UIKit)
    import UIKit
#endif

struct EditorAgentActivityBackground: UIViewRepresentable {
    let state: EditorAgentActivityState
    let accent: Color
    var cornerRadius: Float = 14
    var activityID: String?
    var isEnabled = true
    var effectRadius: Float = 24
    var effectOpacity: Float = 0.45

    func makeUIView(in _: Context) -> EditorAgentActivityBackgroundView {
        let view = EditorAgentActivityBackgroundView()
        view.backgroundColor = .clear
        view.isInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: EditorAgentActivityBackgroundView, in _: Context) {
        view.configure(
            state: state,
            accent: accent,
            cornerRadius: cornerRadius,
            activityID: activityID,
            isEnabled: isEnabled,
            effectRadius: effectRadius,
            effectOpacity: effectOpacity
        )
    }

    func sizeThatFits(_ proposal: ProposedViewSize, view _: EditorAgentActivityBackgroundView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

struct EditorAgentActivityOverlay: View {
    let state: EditorAgentActivityState
    var activityID: String?
    var settings: EditorAppearanceSettings = .shared
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            EditorAgentActivityBackground(
                state: state,
                accent: settings.accentColor(fallback: theme.editorColors.blue),
                cornerRadius: 14,
                activityID: activityID,
                isEnabled: settings.agentActivityGlowEnabled,
                effectRadius: Float(settings.agentGlowRadius),
                effectOpacity: Float(settings.agentGlowOpacity)
            )
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// Kept outside the observed editor tree: animation updates uniforms, never panel layout.
final class EditorAgentActivityBackgroundView: AdaUI.UIView {
    private(set) var animation = EditorAgentGlowAnimation()
    private var material: CustomMaterial<EditorAgentGlowMaterial>?
    private weak var renderWindow: AdaUI.UIWindow?
    private var cornerRadius: Float = 14
    private var effectRadius: Float = 24
    private var lastUpdateUptime: Double?

    func configure(
        state: EditorAgentActivityState,
        accent: Color,
        cornerRadius: Float = 14,
        activityID: String? = nil,
        isEnabled: Bool = true,
        effectRadius: Float = 24,
        effectOpacity: Float = 0.45
    ) {
        isInteractionEnabled = false
        if self.cornerRadius != cornerRadius {
            self.cornerRadius = cornerRadius
            setNeedsDisplay()
        }
        let radius = effectRadius.isFinite ? min(max(effectRadius, 4), 100) : 24
        if self.effectRadius != radius {
            self.effectRadius = radius
            setNeedsDisplay()
        }
        if animation.state != state || animation.activityID != activityID {
            lastUpdateUptime = ProcessInfo.processInfo.systemUptime
        }
        if animation.configure(state: state, accent: accent, activityID: activityID, enabled: isEnabled, opacity: effectOpacity) {
            setNeedsDisplay()
        }
    }

    override func update(_ deltaTime: Float) {
        let now = ProcessInfo.processInfo.systemUptime
        // Real windows use monotonic elapsed time so a background pause cannot extend the success indication.
        // Unattached views use the supplied delta, allowing deterministic previews and tests.
        let elapsed = renderWindow != nil ? lastUpdateUptime.map { Float(max(0, now - $0)) } ?? deltaTime : deltaTime
        lastUpdateUptime = now
        let canDraw = !isHidden && renderWindow?.canDraw != false
        let changed = animation.advance(elapsed, reduceMotion: Self.reduceMotion, wavesEnabled: canDraw && renderWindow?.isActive != false)
        if changed && canDraw {
            setNeedsDisplay()
        }
    }

    override func draw(in rect: Rect, with context: UIGraphicsContext) {
        if let id = context.windowId {
            renderWindow = UIWindowManager.shared.windows[id]
        }
        guard animation.isVisible, rect.width > 2, rect.height > 2 else {
            return
        }
        if material == nil {
            material = CustomMaterial(EditorAgentGlowMaterial())
        }
        guard let material else {
            return
        }
        material.parameters = EditorAgentGlowParameters(
            color: animation.color,
            geometry: Vector4(rect.width, rect.height, animation.time, effectRadius),
            style: Vector4(animation.intensity, animation.hueSpread, cornerRadius, context.opacity * animation.visibility * animation.opacity)
        )
        context.drawShaderEffect(rect, material: material)
    }

    private static var reduceMotion: Bool {
        #if os(macOS)
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #elseif canImport(UIKit)
            UIAccessibility.isReduceMotionEnabled
        #else
            false
        #endif
    }
}

struct EditorAgentGlowAnimation {
    static let fadeDuration: Float = 0.3
    static let successDuration: Float = 3
    private(set) var color = Color.clear
    private(set) var intensity: Float = 0
    private(set) var time: Float = 5
    private(set) var hueSpread: Float = 0.065
    private(set) var motion: Float = 0
    private(set) var visibility: Float = 0
    private(set) var opacity: Float = 0.45
    private(set) var state: EditorAgentActivityState = .idle
    private(set) var activityID: String?
    private var accent = Color.clear
    private var enabled = true
    private var targetOpacity: Float = 0.45
    private var completionAge: Float = 0

    var isVisible: Bool { visibility > 0 && opacity > 0 && intensity > 0 }

    mutating func configure(state: EditorAgentActivityState, accent: Color, activityID: String? = nil, enabled: Bool = true, opacity: Float = 0.45) -> Bool {
        let opacity = opacity.isFinite ? min(max(opacity, 0), 1) : 0.45
        let newActivity = self.state != state || self.activityID != activityID
        guard newActivity || self.accent != accent || self.enabled != enabled || targetOpacity != opacity else {
            return false
        }
        if newActivity {
            completionAge = 0
        }
        // Start a fade from the intended hue, rather than from transparent black.
        if visibility == 0 {
            color = state.color(accent: accent)
            intensity = state.intensity
            self.opacity = opacity
        }
        self.state = state
        self.accent = accent
        self.activityID = activityID
        self.enabled = enabled
        targetOpacity = opacity
        return true
    }

    /// Returns false once the image is static; no recurring invalidation while idle or completed.
    @discardableResult
    mutating func advance(_ deltaTime: Float, reduceMotion: Bool, wavesEnabled: Bool = true) -> Bool {
        let elapsed = deltaTime.isFinite ? max(deltaTime, 0) : 0
        let previousAge = completionAge
        if state == .completed {
            completionAge = min(Self.successDuration, completionAge + elapsed)
        }
        let expired = state == .completed && completionAge >= Self.successDuration
        let shouldShow = enabled && state != .idle && !expired && targetOpacity > 0
        // When one long update crosses the deadline, fade only for the time AFTER the three-second hold.
        let fadeElapsed =
            expired && previousAge < Self.successDuration
            ? max(0, elapsed - (Self.successDuration - previousAge)) : elapsed
        let previousVisibility = visibility
        visibility =
            reduceMotion
            ? (shouldShow ? 1 : 0)
            : min(max(visibility + (shouldShow ? 1 : -1) * fadeElapsed / Self.fadeDuration, 0), 1)
        var changed = previousVisibility != visibility
        if visibility == 0 && !shouldShow {
            intensity = 0
            motion = 0
            opacity = targetOpacity
            return changed
        }
        let delta = min(elapsed, 0.05)
        let blend: Float = reduceMotion ? 1 : 1 - exp(-elapsed * 14)
        func ease(_ current: Float, _ target: Float) -> Float {
            let next = current + (target - current) * blend
            let resolved = abs(next - target) < 0.001 ? target : next
            changed = changed || resolved != current
            return resolved
        }
        let targetColor = state.color(accent: accent)
        color = Color(
            red: ease(color.red, targetColor.red),
            green: ease(color.green, targetColor.green),
            blue: ease(color.blue, targetColor.blue)
        )
        intensity = ease(intensity, state.intensity)
        opacity = ease(opacity, targetOpacity)
        motion = ease(motion, shouldShow ? state.motion : 0)
        hueSpread = ease(hueSpread, state == .working || state == .idle ? 0.065 : 0.012)
        if !reduceMotion, wavesEnabled, motion > 0, isVisible, delta > 0 {
            time += delta * motion
            changed = true
        }
        return changed
    }
}

struct EditorAgentGlowParameters {
    var color: Color
    var geometry: Vector4
    var style: Vector4
}

struct EditorAgentGlowMaterial: UIShaderMaterial {
    // MaterialStorage binds complete reflected blocks, not individual GLSL members.
    @Uniform(binding: 0, propertyName: "EditorAgentGlowMaterial") var parameters: EditorAgentGlowParameters

    init() {
        parameters = EditorAgentGlowParameters(color: .clear, geometry: Vector4(1, 1, 0, 42), style: Vector4(0, 0.065, 14, 1))
    }

    static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        guard let url = Bundle.editor.url(forResource: "agent_activity", withExtension: "glsl", subdirectory: "Assets/Shaders") else {
            throw EditorAgentGlowResourceError.missingShader
        }
        return AssetHandle(try ShaderSource(from: url))
    }

    static func configurePipeline(
        keys _: Set<String>,
        vertex: Shader,
        fragment: Shader,
        vertexDescriptor: VertexDescriptor
    ) throws -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: vertex)
        descriptor.debugName = "Editor Agent Background"
        descriptor.fragment = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.backfaceCulling = true
        descriptor.colorAttachments = [
            RenderPipelineColorAttachmentDescriptor(format: .bgra8, isBlendingEnabled: true, sourceRGBBlendFactor: .one)
        ]
        return descriptor
    }
}

private enum EditorAgentGlowResourceError: LocalizedError {
    case missingShader
    var errorDescription: String? { "Agent activity shader resource is missing." }
}
