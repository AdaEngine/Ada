import AdaEngine

/// Mounts ECS overlays in the native game window. SceneView's offscreen world
/// has a virtual window ID, so overlay UI cannot attach through UIComponentSystem.
@MainActor @Observable
final class EditorSceneUIOverlaySession {
    struct Entry: Identifiable {
        let view: UIView
        var id: ObjectIdentifier { ObjectIdentifier(view) }
    }

    private(set) var views: [Entry] = []
    @ObservationIgnored private var diagnostics: [Entity.ID: String] = [:]

    func prepare(_ world: World) {
        let runtime = world.getResource(UIComponentRuntimeResource.self)?.runtime
        var candidate: [Entry] = []
        var currentDiagnostics: [Entity.ID: String] = [:]
        for entity in world.getEntities() where entity.isActive {
            guard let component = entity.components[UIComponent.self], component.behaviour == .overlay else {
                continue
            }
            do {
                candidate.append(Entry(view: try component.resolveView(runtime: runtime)))
            } catch {
                let message = error.localizedDescription
                currentDiagnostics[entity.id] = message
                if diagnostics[entity.id] != message {
                    RuntimeLogStore.shared.append(level: "error", label: "AdaEditor.UIOverlay", message: message)
                }
            }
        }
        diagnostics = currentDiagnostics
        if views.map(\.id) != candidate.map(\.id) {
            views = candidate
        }
    }
}

struct EditorSceneUIOverlaySurface: UIViewRepresentable {
    let content: UIView

    func makeUIView(in _: Context) -> UIView { content }
    func updateUIView(_: UIView, in _: Context) {}

    func sizeThatFits(_ proposal: ProposedViewSize, view _: UIView, context _: Context) -> Size {
        proposal.replacingUnspecifiedDimensions()
    }
}
