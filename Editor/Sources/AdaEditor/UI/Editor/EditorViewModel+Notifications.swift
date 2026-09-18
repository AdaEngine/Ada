import Foundation

extension EditorViewModel {
    @discardableResult
    func beginWorkspaceActivity(title: String, source: EditorNotificationSource, supportsCancellation: Bool = true) -> String {
        if let previous = notificationWorkspaceRunID {
            EditorNotificationCenter.shared.activities.finish(previous, state: .cancelled)
        }
        let cancel: (() -> Void)? =
            supportsCancellation
            ? { [weak self] in
                guard let self else {
                    return
                }
                // Let the process finish its termination stream before releasing the task.
                Task { await self.workspaceService.cancel() }
            } : nil
        let id = EditorNotificationCenter.shared.activities.begin(
            .init(
                source: source,
                title: title,
                projectName: project?.name,
                action: .init(title: source == .test ? "Open tests" : "Open build", destination: source == .test ? .tests : .build, projectID: project?.id)
            ),
            cancel: cancel
        )
        notificationWorkspaceRunID = id
        return id
    }

    func finishWorkspaceActivity(_ id: String, succeeded: Bool, detail: String = "") {
        EditorNotificationCenter.shared.activities.finish(id, state: succeeded ? .completed : .failed, detail: detail)
        if notificationWorkspaceRunID == id {
            notificationWorkspaceRunID = nil
        }
    }

    func reportProjectError(_ message: String) {
        EditorNotificationCenter.shared.post(
            .init(
                source: .project,
                importance: .error,
                title: "Project operation failed",
                detail: String(message.prefix(600)),
                projectName: project?.name,
                actions: [.init(title: "Project settings", destination: .projectSettings, projectID: project?.id)]
            )
        )
    }
}
