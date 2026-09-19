@_spi(AdaEngine) import AdaEngine
import Foundation

@MainActor
final class EditorNotificationRouter {
    static let shared = EditorNotificationRouter()
    private struct Destination {
        weak var model: EditorViewModel?
        weak var window: UIWindow?
    }
    private var destinations: [Destination] = []
    private var pending: EditorNotificationAction?

    func attach(_ model: EditorViewModel) {
        destinations.removeAll { $0.model == nil || $0.model === model }
        destinations.append(Destination(model: model, window: UIWindowManager.shared?.activeWindow))
        if let pending, pending.projectID == model.project?.id {
            self.pending = nil
            perform(pending, in: model)
        }
    }

    func detach(_ model: EditorViewModel) { destinations.removeAll { $0.model == nil || $0.model === model } }

    func receive(_ action: EditorNotificationAction) {
        if let destination = destinations.last(where: { $0.model != nil && (action.projectID == nil || $0.model?.project?.id == action.projectID) }),
            let model = destination.model {
            destination.window?.showWindow(makeFocused: true)
            perform(action, in: model)
            return
        }
        do {
            let store = EditorProjectStore()
            guard let project = try store.loadProjects().first(where: { $0.id == action.projectID }) else {
                throw CocoaError(.fileNoSuchFile)
            }
            let url = store.resolveProjectURL(for: project)
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw CocoaError(.fileNoSuchFile)
            }
            pending = action
            // This router already buffers URLs until the launch UI is ready and retains iPad bookmarks.
            if destinations.contains(where: { $0.model != nil }) {
                var resolved = project
                #if os(iOS)
                    resolved.path = ProjectOpenPicker.retainSecurityScopedAccess(to: url).path
                #else
                    resolved.path = url.path
                #endif
                ProjectEditorLauncher.openEditor(for: resolved, closing: nil)
            } else {
                EditorProjectOpenURLRouter.shared.receive(url)
            }
        } catch {
            EditorNotificationCenter.shared.post(
                .init(
                    source: .project,
                    importance: .error,
                    title: "Unable to open notification destination",
                    detail: "The project is no longer available. Open it from the project picker.",
                    requestsSystemDelivery: false
                )
            )
        }
    }

    private func perform(_ action: EditorNotificationAction, in model: EditorViewModel) {
        switch action.destination {
        case .chat:
            model.toolStrip.activeRightTool = "agentChat"
            model.showRightPanel = true
            if let id = action.sessionID {
                model.agent.openNotificationSession(id)
            }
        case .build,
            .tests:
            model.selectOutputTab(action.destination == .tests ? "Tests" : "Build")
            model.showBottomPanel = true
            model.toolStrip.activeLeftBottomTool = "build"
        case .projectSettings: model.presentSettings(.project, page: action.settingsPage)
        case .agentSettings: model.presentSettings(.agent)
        case .sourceControl:
            model.toolStrip.activeLeftTopTool = "sourceControl"
            model.showLeftPanel = true
        case .activity:
            model.notificationTab = .activity
            model.showsNotifications = true
        }
    }
}
