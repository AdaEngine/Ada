import Foundation

#if os(iOS)
    import BackgroundTasks
    import UIKit

    /// Opt-in bridge for user-started executors that report measurable work and support cancellation.
    /// ACP subprocesses do not opt in: they are unavailable on iPadOS.
    @available(iOS 26.0, *)
    @MainActor
    final class EditorContinuedProcessing {
        static let shared = EditorContinuedProcessing()
        private var registered = Set<String>()

        func request(for id: String, coordinator: EditorActivityCoordinator) {
            guard let activity = coordinator.active.first(where: { $0.id == id }) else {
                return
            }
            guard
                UIApplication.shared.applicationState == .active,
                activity.totalUnits.map({ $0 > 0 }) == true,
                coordinator.canCancel(id)
            else {
                coordinator.update(id, detail: activity.detail, backgroundStatus: "Foreground only: measurable progress and cancellation are required.")
                return
            }
            let identifier = "org.adaengine.editor.continued.\(id)"
            guard !registered.contains(identifier) else {
                return
            }
            let didRegister = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { task in
                MainActor.assumeIsolated {
                    guard let task = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    task.expirationHandler = {
                        Task { @MainActor in coordinator.cancel(id, interrupted: true) }
                    }
                    coordinator.attachBackground(EditorContinuedExecution(task: task), to: id)
                    coordinator.update(
                        id,
                        detail: coordinator.active.first(where: { $0.id == id })?.detail ?? "Running",
                        backgroundStatus: "Can continue in the background"
                    )
                }
            }
            guard didRegister else {
                coordinator.update(id, detail: activity.detail, backgroundStatus: "Foreground only: background task registration failed.")
                return
            }
            registered.insert(identifier)
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: activity.title,
                subtitle: activity.projectName ?? activity.detail
            )
            request.strategy = .fail
            do { try BGTaskScheduler.shared.submit(request) } catch {
                coordinator.update(id, detail: activity.detail, backgroundStatus: "Foreground only: \(error.localizedDescription)")
            }
        }
    }

    @available(iOS 26.0, *)
    @MainActor
    private final class EditorContinuedExecution: EditorBackgroundExecution {
        private var task: BGContinuedProcessingTask?
        init(task: BGContinuedProcessingTask) { self.task = task }

        func update(_ activity: EditorOperationActivity) {
            guard let task else {
                return
            }
            task.updateTitle(activity.title, subtitle: activity.detail.isEmpty ? "Running" : activity.detail)
            if let total = activity.totalUnits, let completed = activity.completedUnits {
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = completed
            }
        }

        func finish(success: Bool) {
            guard let task else {
                return
            }
            self.task = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
    }
#endif
