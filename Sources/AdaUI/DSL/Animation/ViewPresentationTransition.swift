import AdaAnimation
import AdaInput
import AdaUtils
import Math

@MainActor
protocol PresentationInputProviding {
    var inputContentNodes: [ViewNode] { get }
}

extension ViewNode {
    var acceptsPresentationInput: Bool {
        var child: ViewNode = self
        while let parent = child.parent {
            if let presentation = parent as? PresentationInputProviding,
               !presentation.inputContentNodes.contains(where: { $0 === child }) {
                return false
            }
            child = parent
        }
        return child is ViewRootNode
    }
}

/// Owns the presentation of retained screens. Layout remains at its final size;
/// only drawing and hit testing use the interpolated transform.
@MainActor
final class ViewPresentationTransition {
    enum Style {
        case push, pop, tabs, sheet, cover

        var insertion: Pose {
            switch self {
            case .push: Pose(x: 1)
            case .pop: Pose(x: -0.25, opacity: 0.7)
            case .tabs: Pose(scale: 0.96, opacity: 0)
            case .sheet: Pose(y: 0.05, scale: 0.94, opacity: 0)
            case .cover: Pose(y: 1)
            }
        }

        var removal: Pose {
            switch self {
            case .push: Pose(x: -0.25, opacity: 0.7)
            case .pop: Pose(x: 1)
            case .tabs: Pose(scale: 1.04, opacity: 0)
            case .sheet, .cover: insertion
            }
        }
    }

    struct Pose: Animatable {
        var x: Float = 0
        var y: Float = 0
        var scale: Float = 1
        var opacity: Float = 1

        var animatableData: Vector4 {
            get { Vector4(x, y, scale, opacity) }
            set { x = newValue.x; y = newValue.y; scale = newValue.z; opacity = newValue.w }
        }
    }

    final class Entry {
        let node: ViewNode
        var pose: Pose

        init(node: ViewNode, pose: Pose) {
            self.node = node
            self.pose = pose
        }
    }

    private weak var host: ViewNode?
    private(set) var entries: [Entry] = []
    private(set) var selected: ViewNode?
    private var controller: UIAnimationController?
    var isAnimating: Bool { controller?.isPlaying == true }
    var nodes: [ViewNode] { entries.map(\.node) }

    init(host: ViewNode) {
        self.host = host
    }

    func setContent(_ node: ViewNode?, style: Style, animated: Bool = true) {
        guard selected !== node else {
            return
        }
        guard let host else {
            return
        }
        controller?.stopAnimation()
        if let previous = selected { host.owner?.deactivateInput(in: previous) }
        selected = node

        if let node {
            if !entries.contains(where: { $0.node === node }) {
                let entry = Entry(node: node, pose: style.insertion)
                if style == .pop {
                    entries.insert(entry, at: 0)
                } else {
                    entries.append(entry)
                }
            }
            node.parent = host
            if let owner = host.owner { node.updateViewOwner(owner) }
        }

        let transaction = UITransactionContext.current
        let animation = transaction.map { $0.disablesAnimations ? nil : $0.animation } ?? .easeInOut(duration: 0.28)
        guard animated, host.owner != nil, host.frame.width > 0,
              !host.environment.animationsDisabled, let animation else {
            finish()
            return
        }

        let controller = UIAnimationController(animation: animation)
        self.controller = controller
        for entry in entries {
            let target = entry.node === node ? Pose() : style.removal
            controller.addTweenAnimation(
                from: entry.pose, to: target, label: entry.node.id, environment: host.environment
            ) { [weak self, weak entry] pose in
                entry?.pose = pose
                self?.invalidateDisplay()
            }
        }
        controller.playAnimation()
        invalidateDisplay()
    }

    func layout(in bounds: Rect) {
        for entry in entries {
            entry.node.performWithTransientAnimationController(nil) {
                entry.node.place(in: Point(bounds.midX, bounds.midY), anchor: .center, proposal: ProposedViewSize(bounds.size))
            }
        }
    }

    func update(_ deltaTime: TimeInterval) {
        for entry in entries { entry.node.update(deltaTime) }
        guard let controller else {
            return
        }
        if host?.environment.animationsDisabled == true {
            controller.stopAnimation()
            finish()
            return
        }
        controller.update(deltaTime)
        if !controller.isPlaying { finish() }
    }

    func draw(with context: UIGraphicsContext, in bounds: Rect) {
        var path = Path()
        path.addRect(bounds)
        var context = context
        context.clip(to: path) { clipped in
            for entry in entries {
                var drawing = clipped
                let center = Point(entry.node.frame.midX, entry.node.frame.midY)
                drawing.translateBy(x: center.x + entry.pose.x * bounds.width, y: -center.y - entry.pose.y * bounds.height)
                drawing.concatenate(Transform3D(scale: Vector3(entry.pose.scale, entry.pose.scale, 1)))
                drawing.translateBy(x: -center.x, y: center.y)
                drawing.opacity *= entry.pose.opacity
                entry.node.draw(with: drawing)
                // The UI renderer batches quads and glyphs separately. End the
                // screen's batch before drawing the next screen's background.
                drawing.commitDraw()
            }
        }
    }

    func hitTest(_ point: Point, event: any InputEvent, in bounds: Rect) -> ViewNode? {
        guard bounds.contains(point: point), let host,
              let entry = entries.first(where: { $0.node === selected }),
              entry.pose.opacity > 0.001, entry.pose.scale > 0 else {
                  return nil
              }
        let center = Point(entry.node.frame.midX, entry.node.frame.midY)
        let untransformed = Point(
            (point.x - center.x - entry.pose.x * bounds.width) / entry.pose.scale + center.x,
            (point.y - center.y - entry.pose.y * bounds.height) / entry.pose.scale + center.y
        )
        return entry.node.hitTest(entry.node.convert(untransformed, from: host), with: event)
    }

    func detach() {
        controller?.stopAnimation()
        controller = nil
        entries.forEach { $0.node.parent = nil }
        entries.removeAll()
        selected = nil
    }

    private func finish() {
        for entry in entries where entry.node !== selected { entry.node.parent = nil }
        entries.removeAll { $0.node !== selected }
        entries.first?.pose = Pose()
        controller = nil
        invalidateDisplay()
    }

    private func invalidateDisplay() {
        host?.invalidateNearestLayer()
        if let host { host.owner?.containerView?.setNeedsDisplay(in: host.visualAbsoluteFrame()) }
    }
}
