@_spi(AdaEngine) import AdaEngine
import AdaUI
import Foundation
import Math

#if os(iOS)
import UIKit

/// The Companion Bubble drawn in AdaUI, so it participates in clipping and covers.
struct MobileEditorVoiceOrb: UIViewRepresentable {
    var activity: MobileVoiceOrbActivity = .idle
    var audioLevel: Float = 0

    func makeUIView(in _: Context) -> MobileEditorVoiceOrbView {
        let view = MobileEditorVoiceOrbView()
        view.backgroundColor = .clear
        view.isInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: MobileEditorVoiceOrbView, in _: Context) {
        view.animation.activity = activity
        view.animation.audioLevel = audioLevel
        view.setNeedsDisplay()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, view _: MobileEditorVoiceOrbView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}

final class MobileEditorVoiceOrbView: AdaUI.UIView {
    var animation = MobileVoiceOrbAnimation()
    private var material: CustomMaterial<MobileVoiceOrbMaterial>?
    private weak var renderWindow: AdaUI.UIWindow?

    override func update(_ deltaTime: Float) {
        guard !isHidden, renderWindow?.canDraw != false, renderWindow?.isActive != false else {
            return
        }
        if animation.advance(deltaTime, reduceMotion: UIAccessibility.isReduceMotionEnabled) { setNeedsDisplay() }
    }

    override func draw(in rect: Rect, with context: UIGraphicsContext) {
        if let id = context.windowId { renderWindow = UIWindowManager.shared.windows[id] }
        guard rect.width > 0, rect.height > 0 else {
            return
        }
        if material == nil { material = CustomMaterial(MobileVoiceOrbMaterial()) }
        guard let material else {
            return
        }
        material.parameters = MobileVoiceOrbParameters(
            geometry: Vector4(rect.width, rect.height, animation.time, animation.level),
            style: Vector4(context.opacity, 0, 0, 0)
        )
        context.drawShaderEffect(rect, material: material)
    }
}
#endif

enum MobileVoiceOrbActivity { case idle, listening, working, speaking }

struct MobileVoiceOrbAnimation {
    var activity: MobileVoiceOrbActivity = .idle
    var audioLevel: Float = 0
    private(set) var time: Float = 8
    private(set) var level: Float = 0

    @discardableResult
    mutating func advance(_ deltaTime: Float, reduceMotion: Bool) -> Bool {
        if reduceMotion {
            let changed = time != 8 || level != 0
            time = 8
            level = 0
            return changed
        }
        let delta = deltaTime.isFinite ? min(max(deltaTime, 0), 0.05) : 0
        guard delta > 0 else {
            return false
        }
        let target: Float
        switch activity {
        case .listening: target = audioLevel.isFinite ? min(max(audioLevel, 0), 1) : 0
        case .speaking: target = 0.2 + 0.12 * Foundation.sin(time * 4)
        case .idle, .working: target = 0
        }
        level += (target - level) * (1 - exp(-delta * (target > level ? 14 : 5)))
        time += delta * (activity == .working ? 3 : 2) * (1 + level * 0.5)
        return true
    }
}

struct MobileVoiceOrbParameters {
    var geometry: Vector4
    var style: Vector4
}

struct MobileVoiceOrbMaterial: UIShaderMaterial {
    @Uniform(binding: 0, propertyName: "MobileVoiceOrbMaterial") var parameters: MobileVoiceOrbParameters

    init() {
        parameters = MobileVoiceOrbParameters(geometry: Vector4(1, 1, 8, 0), style: Vector4(1, 0, 0, 0))
    }

    static func fragmentShader() throws -> AssetHandle<ShaderSource> {
        guard let url = Bundle.editor.url(forResource: "mobile_voice_orb", withExtension: "glsl", subdirectory: "Assets/Shaders") else {
            throw CocoaError(.fileNoSuchFile)
        }
        return AssetHandle(try ShaderSource(from: url))
    }

    static func configurePipeline(keys _: Set<String>, vertex: Shader, fragment: Shader, vertexDescriptor: VertexDescriptor) throws -> RenderPipelineDescriptor {
        var descriptor = RenderPipelineDescriptor(vertex: vertex)
        descriptor.debugName = "Mobile Voice Bubble"
        descriptor.fragment = fragment
        descriptor.vertexDescriptor = vertexDescriptor
        descriptor.backfaceCulling = true
        descriptor.colorAttachments = [RenderPipelineColorAttachmentDescriptor(format: .bgra8, isBlendingEnabled: true, sourceRGBBlendFactor: .one)]
        return descriptor
    }
}
