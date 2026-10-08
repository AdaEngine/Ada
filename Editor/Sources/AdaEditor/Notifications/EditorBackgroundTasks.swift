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

        func request(for id: String, coordinator: EditorActivityCoordinator, onUnavailable: ((String) -> Void)? = nil) {
            guard let activity = coordinator.active.first(where: { $0.id == id }) else {
                return
            }
            guard
                UIApplication.shared.applicationState == .active,
                activity.totalUnits.map({ $0 > 0 }) == true,
                coordinator.canCancel(id)
            else {
                coordinator.update(id, detail: activity.detail, backgroundStatus: "Foreground only: measurable progress and cancellation are required.")
                onUnavailable?("Start the agent while the application is active. Background work requires progress and cancellation support.")
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
                        Task { @MainActor in
                            coordinator.cancel(id, interrupted: true, detail: "iOS stopped background execution or the system Activity was cancelled.")
                        }
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
                onUnavailable?("The system could not register background execution. Keep the app open for this request.")
                return
            }
            registered.insert(identifier)
            let request = BGContinuedProcessingTaskRequest(
                identifier: identifier,
                title: activity.title,
                subtitle: activity.systemSubtitle()
            )
            request.strategy = .fail
            do { try BGTaskScheduler.shared.submit(request) } catch {
                let message = Self.unavailableMessage(error)
                coordinator.update(id, detail: activity.detail, backgroundStatus: message)
                onUnavailable?(message)
            }
        }

        private static func unavailableMessage(_ error: any Error) -> String {
            let error = error as NSError
            guard error.domain == "BGTaskSchedulerErrorDomain" else {
                return "\(error.localizedDescription) Keep the app open for this request."
            }
            switch error.code {
            case 1:
                #if targetEnvironment(simulator)
                    return "Simulator cannot run background processing. Test on an iPhone or iPad; keep the app open here."
                #else
                    return "Background processing is unavailable. Enable Background App Refresh in Settings or keep the app open."
                #endif
            case 2:
                return "Too many background tasks are active. Keep the app open for this request."
            case 3:
                return "iOS did not permit background processing. Check Background App Refresh in Settings or keep the app open."
            case 4:
                return "iOS cannot grant background time under current system conditions. Keep the app open for this request."
            default:
                return "\(error.localizedDescription) Keep the app open for this request."
            }
        }
    }

    @available(iOS 26.0, *)
    @MainActor
    private final class EditorContinuedExecution: EditorBackgroundExecution {
        private var task: BGContinuedProcessingTask?
        private var activity: EditorOperationActivity?
        private var timer: Task<Void, Never>?

        init(task: BGContinuedProcessingTask) {
            self.task = task
            timer = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(15)) } catch { return }
                    guard let self, self.task != nil else {
                        return
                    }
                    refreshSubtitle()
                }
            }
        }

        func update(_ activity: EditorOperationActivity) {
            guard let task else {
                return
            }
            self.activity = activity
            refreshSubtitle()
            if let total = activity.totalUnits, let completed = activity.completedUnits {
                task.progress.totalUnitCount = total
                task.progress.completedUnitCount = completed
            }
        }

        private func refreshSubtitle() {
            guard let task, let activity else {
                return
            }
            task.updateTitle(activity.title, subtitle: activity.systemSubtitle())
        }

        func finish(success: Bool) {
            guard let task else {
                return
            }
            self.task = nil
            timer?.cancel()
            timer = nil
            task.expirationHandler = nil
            task.setTaskCompleted(success: success)
        }
    }
#endif
