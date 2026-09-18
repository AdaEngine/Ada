import AdaApp
import AdaECS
import AdaRender
import AdaUI
import AdaUtils
import Math
import Observation

/// Embeds one persistent scene runtime and its optional companion UI in application display regions.
/// Changing `layout` never creates a second world or restarts the scene. `nil` uses the available size.
public struct AdaptiveSceneView: View {
    private let layout: DisplayLayout?
    private let fitsAvailableSpace: Bool
    private let make: @MainActor (inout AppWorlds) -> Void
    private let updateContent: @MainActor (World, AdaUtils.TimeInterval) -> Void
    @State private var session = AdaptiveSceneSession()

    public init(
        layout: DisplayLayout? = nil,
        fitsAvailableSpace: Bool = true,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void = { _, _ in }
    ) {
        self.layout = layout
        self.fitsAvailableSpace = fitsAvailableSpace
        self.make = make
        self.updateContent = updateContent
    }

    public var body: some View {
        GeometryReader { geometry in
            let resolved = layout ?? .standard(size: geometry.size)
            let surface = session.configure(layout: resolved, make: make, updateContent: updateContent)
            AdaptiveSurface(content: surface, contentSize: resolved.size, zoom: fitsAvailableSpace ? resolved.fitScale(in: geometry.size) : 1)
                .mask(RectangleShape())
        }
    }
}

@MainActor @Observable
final class AdaptiveSceneSession {
    var layout = DisplayLayout.standard(size: Size(width: 400, height: 640))
    var companionView: UIView?
    var diagnostic: String?
    @ObservationIgnored private weak var surface: UIView?
    @ObservationIgnored private var panelEntityID: Entity.ID?
    @ObservationIgnored private var panelSource: UIComponentSource?

    func configure(
        layout: DisplayLayout,
        make: @escaping @MainActor (inout AppWorlds) -> Void,
        updateContent: @escaping @MainActor (World, AdaUtils.TimeInterval) -> Void
    ) -> UIView {
        if self.layout != layout {
            self.layout = layout
        }
        if let surface {
            return surface
        }
        let container = UIContainerView(rootView: AdaptiveSceneContent(session: self, make: make, updateContent: updateContent))
        container.backgroundColor = .clear
        surface = container
        return container
    }

    func prepare(_ world: World) {
        if world.getResource(DisplayLayout.self) != layout {
            world.insertResource(layout)
        }
        var panel: (Entity, CompanionPanel)?
        for entity in world.getEntities() {
            guard let component = entity.components[CompanionPanel.self] else {
                continue
            }
            if panel != nil {
                diagnostic = "Only one Companion Panel can be presented per scene."
                companionView = nil
                return
            }
            panel = (entity, component)
        }
        guard let (entity, component) = panel else {
            companionView = nil
            panelEntityID = nil
            panelSource = nil
            diagnostic = nil
            return
        }
        guard entity.id != panelEntityID || component.ui.source != panelSource else {
            return
        }
        panelEntityID = entity.id
        panelSource = component.ui.source
        do {
            companionView = try component.ui.resolveView(runtime: world.getResource(UIComponentRuntimeResource.self)?.runtime)
            diagnostic = nil
        } catch {
            companionView = nil
            diagnostic = error.localizedDescription
        }
    }
}

private struct AdaptiveSceneContent: View {
    let session: AdaptiveSceneSession
    let make: @MainActor (inout AppWorlds) -> Void
    let updateContent: @MainActor (World, AdaUtils.TimeInterval) -> Void

    var body: some View {
        HStack(spacing: 0) {
            SceneView(
                make: { app in
                    app.main.insertResource(EmbeddedDisplayLayout())
                    app.main.insertResource(session.layout)
                    make(&app)
                },
                updateContent: { world, delta in
                    session.prepare(world)
                    updateContent(world, delta)
                }
            )
            .frame(width: session.layout.primary.width, height: session.layout.primary.height)
            .accessibilityIdentifier("AdaEngine.Adaptive.Primary")

            Color.black
                .frame(width: session.layout.hinge?.width ?? 0, height: session.layout.primary.height)
                .allowsHitTesting(false)

            if let region = session.layout.secondary {
                ZStack {
                    Color.black
                    if let view = session.companionView {
                        CompanionSurface(content: view)
                    } else {
                        Text(session.diagnostic ?? "Add a Companion Panel to this scene.")
                            .foregroundColor(.white).padding(24)
                    }
                }
                .frame(width: region.width, height: region.height)
                .mask(RectangleShape())
                .accessibilityIdentifier("AdaEngine.Adaptive.Secondary")
            }
        }
    }
}

private struct CompanionSurface: UIViewRepresentable {
    let content: UIView
    func makeUIView(in _: Context) -> UIView { content }
    func updateUIView(_: UIView, in _: Context) {}
    func sizeThatFits(_ proposal: ProposedViewSize, view _: UIView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}
