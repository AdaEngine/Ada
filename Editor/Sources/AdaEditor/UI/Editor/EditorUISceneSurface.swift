@_spi(AdaEngine) import AdaEngine
import AdaInput
@_spi(Internal) import AdaUI
import Math

struct EditorUISceneSurface: UIViewRepresentable {
    let preview: UIView
    let model: EditorUISceneModel
    var zoom: Float?
    func makeUIView(in _: Context) -> EditorUISceneHost { EditorUISceneHost(frame: .zero) }
    func updateUIView(_ view: EditorUISceneHost, in _: Context) {
        view.model = model
        view.host.configure(
            previewView: preview,
            zoom: zoom ?? model.zoom,
            isInteractive: model.isInteractive,
            contentSize: Size(width: model.width, height: model.height)
        )
        view.setNeedsDisplay()
    }
}

final class EditorUISceneHost: UIView {
    let host = EditorPreviewHostView()
    weak var model: EditorUISceneModel?

    required init(frame: Rect) {
        super.init(frame: frame)
        backgroundColor = .clear
        addSubview(host)
    }
    override func layoutSubviews() {
        host.frame = bounds
        super.layoutSubviews()
    }
    override func hitTest(_ point: Point, with event: any InputEvent) -> UIView? {
        guard bounds.contains(point: point) else {
            return nil
        }
        return model?.isInteractive == true ? host.hitTest(point, with: event) : self
    }
    override func onMouseEvent(_ event: MouseEvent) {
        guard model?.isInteractive == false, event.phase == .ended else {
            return
        }
        select(at: host.previewPoint(from: event.mousePosition))
    }
    override func onTouchesEvent(_ touches: Set<TouchEvent>) {
        if let touch = touches.first(where: { $0.phase == .ended }), model?.isInteractive == false {
            select(at: host.previewPoint(from: touch.location))
        }
    }
    override func draw(with context: UIGraphicsContext) {
        super.draw(with: context)
        guard let model, !model.isInteractive, let preview = host.previewView as? UIContainerView<UISceneView> else {
            return
        }
        func selectedFrames(_ node: UINodeSnapshot) -> [Rect] {
            (node.sceneNodeID == model.selectedID ? [node.absoluteFrame] : []) + node.children.flatMap(selectedFrames)
        }
        let zoom = host.zoom
        let origin = Point(x: frame.minX + (bounds.width - model.width * zoom) / 2, y: frame.minY + (bounds.height - model.height * zoom) / 2)
        for source in preview.uiTreeRoots().flatMap(selectedFrames) {
            let rect = Rect(
                x: origin.x + source.minX * zoom,
                y: origin.y + source.minY * zoom,
                width: source.width * zoom,
                height: source.height * zoom
            )
            context.drawRect(Rect(x: rect.minX, y: rect.minY, width: rect.width, height: 1), color: .blue)
            context.drawRect(Rect(x: rect.minX, y: rect.maxY - 1, width: rect.width, height: 1), color: .blue)
            context.drawRect(Rect(x: rect.minX, y: rect.minY, width: 1, height: rect.height), color: .blue)
            context.drawRect(Rect(x: rect.maxX - 1, y: rect.minY, width: 1, height: rect.height), color: .blue)
        }
    }

    private func select(at point: Point) {
        guard let preview = host.previewView as? UIContainerView<UISceneView> else {
            return
        }
        let roots = preview.uiTreeRoots()
        func find(_ node: UINodeSnapshot) -> String? {
            for child in node.children.reversed() {
                if let match = find(child) {
                    return match
                }
            }
            guard node.absoluteFrame.contains(point: point), let id = node.sceneNodeID else {
                return nil
            }
            var belongs = false
            model?.document.root
                .visit {
                    if $0.id == id {
                        belongs = true
                    }
                }
            return belongs ? id : nil
        }
        if let selected = roots.compactMap(find).first {
            model?.selectedID = selected
        }
    }
}
