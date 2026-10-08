//
//  KeyframeAnimator+View.swift
//  AdaEngine
//

import AdaAnimation
import AdaUtils
import Math

/// A keyframe value that knows how to apply itself to an AdaUI view node.
public protocol UIKeyframeAnimatable: Sendable {
    /// Writes the evaluated keyframe value into the target view node.
    @MainActor
    func apply(to node: KeyframeAnimatorNodeProxy)
}

/// Public handle exposed to ``UIKeyframeAnimatable`` values.
///
/// The proxy keeps `ViewNode` internal while still allowing keyframe values to
/// update the animated node's render state.
@MainActor
public struct KeyframeAnimatorNodeProxy {
    private weak var node: (any KeyframeAnimatorNodeProxyTarget)?

    init(node: any KeyframeAnimatorNodeProxyTarget) {
        self.node = node
    }

    /// Additional transform concatenated before drawing the modified view.
    public var transform: Transform3D {
        get { node?.animatedTransform ?? .identity }
        nonmutating set {
            node?.animatedTransform = newValue
            node?.invalidateDisplay()
        }
    }

    /// Opacity multiplier applied while drawing the modified view.
    public var opacity: Float {
        get { node?.animatedOpacity ?? 1 }
        nonmutating set {
            node?.animatedOpacity = newValue
            node?.invalidateDisplay()
        }
    }

    /// Current laid out frame of the animated node.
    public var frame: Rect {
        node?.frame ?? .zero
    }

    /// Current environment of the animated node.
    public var environment: EnvironmentValues {
        node?.environment ?? EnvironmentValues()
    }

    /// Marks the node as needing a layout pass.
    public func invalidateLayout() {
        node?.invalidateLayout()
    }

    /// Invalidates the nearest cached layer so animated render state is drawn again.
    public func invalidateDisplay() {
        node?.invalidateDisplay()
    }
}

extension View {
    /// Attaches a keyframe animation to this view node.
    @MainActor
    public func keyframeAnimator<Value: UIKeyframeAnimatable>(
        _ clip: KeyframeClip<Value>,
        speed: Double = 1,
        isPlaying: Bool = true
    ) -> some View {
        keyframeAnimator(
            initialClipName: clip.name,
            speed: speed,
            isPlaying: isPlaying
        ) {
            clip
        }
    }

    /// Attaches keyframe animation clips to this view node.
    @MainActor
    public func keyframeAnimator<Value: UIKeyframeAnimatable>(
        initialClipName: String? = nil,
        speed: Double = 1,
        isPlaying: Bool = true,
        @KeyframeNodeAnimatorBuilder<Value> _ build: () -> [KeyframeClip<Value>]
    ) -> some View {
        modifier(
            KeyframeAnimatorViewModifier(
                content: self,
                clips: build(),
                initialClipName: initialClipName,
                speed: speed,
                isPlaying: isPlaying
            )
        )
    }
}

@resultBuilder
public enum KeyframeNodeAnimatorBuilder<Value: UIKeyframeAnimatable> {
    public static func buildBlock(_ clips: KeyframeClip<Value>...) -> [KeyframeClip<Value>] {
        clips
    }

    public static func buildExpression(_ clip: KeyframeClip<Value>) -> KeyframeClip<Value> {
        clip
    }
}

protocol KeyframeAnimatorNodeProxyTarget: AnyObject {
    @MainActor var animatedTransform: Transform3D { get set }
    @MainActor var animatedOpacity: Float { get set }
    @MainActor var frame: Rect { get }
    @MainActor var environment: EnvironmentValues { get }

    @MainActor
    func invalidateLayout()

    @MainActor
    func invalidateDisplay()
}

private struct KeyframeAnimatorViewModifier<Content: View, Value: UIKeyframeAnimatable>: ViewModifier, ViewNodeBuilder {
    typealias Body = Never

    let content: Content
    let clips: [KeyframeClip<Value>]
    let initialClipName: String?
    let speed: Double
    let isPlaying: Bool

    func buildViewNode(in context: BuildContext) -> ViewNode {
        KeyframeAnimatorViewNode(
            contentNode: context.makeNode(from: content),
            content: content,
            clips: clips,
            initialClipName: initialClipName,
            speed: speed,
            isPlaying: isPlaying
        )
    }
}

final class KeyframeAnimatorViewNode<Value: UIKeyframeAnimatable>: ViewModifierNode, KeyframeAnimatorNodeProxyTarget {
    private var clipsByName: [String: KeyframeClip<Value>]
    private var initialClipName: String?
    private var currentClipName: String?
    private var localTime: TimeInterval = 0
    private var speed: Double
    private var isPlaying: Bool

    var animatedTransform: Transform3D = .identity
    var animatedOpacity: Float = 1

    init<Content: View>(
        contentNode: ViewNode,
        content: Content,
        clips: [KeyframeClip<Value>],
        initialClipName: String?,
        speed: Double,
        isPlaying: Bool
    ) {
        self.clipsByName = Self.makeClipsByName(clips)
        self.initialClipName = initialClipName
        self.currentClipName = Self.resolveInitialClipName(initialClipName, clips: clips)
        self.speed = speed
        self.isPlaying = isPlaying
        super.init(contentNode: contentNode, content: content)
        applyCurrentValue()
    }

    override func update(from newNode: ViewNode) {
        guard let other = newNode as? Self else {
            super.update(from: newNode)
            return
        }

        let previousInitialClipName = initialClipName
        super.update(from: other)

        clipsByName = other.clipsByName
        initialClipName = other.initialClipName
        speed = other.speed
        isPlaying = other.isPlaying

        if initialClipName != previousInitialClipName || currentClipName.flatMap({ clipsByName[$0] }) == nil {
            currentClipName = other.currentClipName
            localTime = 0
        }

        applyCurrentValue()
    }

    override func update(_ deltaTime: TimeInterval) {
        super.update(deltaTime)

        guard isPlaying, let clip = currentClip else {
            return
        }

        localTime += TimeInterval(Double(deltaTime) * speed)
        let state = keyframePlaybackState(
            playhead: localTime,
            duration: clip.duration,
            mode: clip.repeatMode
        )
        apply(clip: clip, localTime: state.localTime)

        if state.isFinished {
            isPlaying = false
        }
    }

    override func draw(with context: UIGraphicsContext) {
        var context = context
        context.opacity *= animatedOpacity
        context.concatenate(animatedTransform)
        super.draw(with: context)
    }

    func invalidateLayout() {
        markNeedsLayout()
    }

    func invalidateDisplay() {
        invalidateNearestLayer()
    }

    private var currentClip: KeyframeClip<Value>? {
        currentClipName.flatMap { clipsByName[$0] }
    }

    private func applyCurrentValue() {
        guard let clip = currentClip else {
            return
        }

        let state = keyframePlaybackState(
            playhead: localTime,
            duration: clip.duration,
            mode: clip.repeatMode
        )
        apply(clip: clip, localTime: state.localTime)
    }

    private func apply(clip: KeyframeClip<Value>, localTime: TimeInterval) {
        let value = clip.evaluate(at: localTime)
        value.apply(to: KeyframeAnimatorNodeProxy(node: self))
        invalidateDisplay()
    }

    private static func makeClipsByName(_ clips: [KeyframeClip<Value>]) -> [String: KeyframeClip<Value>] {
        var map: [String: KeyframeClip<Value>] = [:]
        for clip in clips where !clip.name.isEmpty {
            map[clip.name] = clip
        }
        return map
    }

    private static func resolveInitialClipName(_ initialClipName: String?, clips: [KeyframeClip<Value>]) -> String? {
        initialClipName ?? clips.first?.name
    }
}
