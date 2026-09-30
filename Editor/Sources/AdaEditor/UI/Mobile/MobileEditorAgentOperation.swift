import Foundation

/// Owns a user-started turn independently of the visible project or window.
@MainActor
final class MobileEditorAgentOperation {
    struct Outcome {
        let succeeded: Bool
        let detail: String
    }

    let id = UUID().uuidString
    let projectID: UUID
    private let center: EditorNotificationCenter
    private var worker: Task<Void, Never>?
    private var completedSteps: Int64 = 0
    private var lastError: String?
    private var errorTool: String?
    private var detail = "Connecting to the model…"

    init(projectID: UUID, center: EditorNotificationCenter = .shared) {
        self.projectID = projectID
        self.center = center
    }

    func start(
        projectName: String,
        requestBackground: (String, EditorActivityCoordinator) -> Void,
        work: @escaping @MainActor () async throws -> Outcome,
        finished: @escaping @MainActor (EditorOperationActivity.State, String) async -> Void
    ) {
        guard worker == nil, !center.activities.all.contains(where: { $0.id == id }) else {
            return
        }
        center.activities.begin(
            .init(
                id: id,
                source: .agent,
                title: "Agent · \(projectName)",
                projectName: projectName,
                action: .init(title: "Open chat", destination: .chat, projectID: projectID.uuidString, sessionID: projectID.uuidString),
                detail: detail,
                completedUnits: 0,
                totalUnits: 1
            ),
            cancel: { [weak self] in self?.worker?.cancel() }
        )
        // Install cancellation before the system can grant or expire the request.
        worker = Task {
            let resultState: EditorOperationActivity.State
            let resultDetail: String
            do {
                try Task.checkCancellation()
                let outcome = try await work()
                try Task.checkCancellation()
                resultState = outcome.succeeded ? .completed : .failed
                resultDetail = outcome.detail
            } catch {
                let terminal = center.activities.all.first { $0.id == id }?.state
                if Task.isCancelled || error is CancellationError {
                    resultState = terminal == .interrupted ? .interrupted : .cancelled
                    resultDetail = resultState == .interrupted
                        ? "iOS stopped background execution. Open the chat and send a new request to continue."
                        : "Agent stopped. Changes already saved to the project are retained."
                } else {
                    resultState = .failed
                    resultDetail = error.localizedDescription
                }
            }
            if resultState == .completed {
                center.activities.update(id, detail: resultDetail, completed: completedSteps + 1, total: completedSteps + 1)
            }
            center.activities.finish(id, state: resultState, detail: resultDetail)
            if resultState == .completed {
                center.post(.init(
                    id: "\(id):result",
                    source: .agent,
                    importance: .success,
                    title: "Agent completed",
                    detail: resultDetail,
                    projectName: projectName,
                    operationID: id,
                    actions: [.init(title: "Open chat", destination: .chat, projectID: projectID.uuidString, sessionID: projectID.uuidString)]
                ))
            }
            await finished(resultState, resultDetail)
            worker = nil
        }
        requestBackground(id, center.activities)
    }

    func update(_ value: String) {
        guard detail != value else {
            return
        }
        detail = value
        publish()
    }

    func completedStep() {
        completedSteps += 1
        publish()
    }

    func reportError(_ message: String, tool: String? = nil) {
        guard center.activities.active.contains(where: { $0.id == id }) else {
            return
        }
        lastError = String(message.prefix(300))
        errorTool = tool
        center.post(.init(
            id: "\(id):error:\(completedSteps)",
            source: .agent,
            importance: .error,
            title: "Agent encountered an error",
            detail: message,
            operationID: id,
            actions: [.init(title: "Open chat", destination: .chat, projectID: projectID.uuidString, sessionID: projectID.uuidString)],
            requestsSystemDelivery: false
        ))
        publish()
    }

    func failedTool(_ tool: String) {
        if errorTool != tool { reportError("\(tool) failed; the agent is checking the result.", tool: tool) }
    }

    func backgroundUnavailable(_ message: String) {
        center.post(.init(
            id: "\(id):background",
            source: .agent,
            importance: .warning,
            title: "Background execution unavailable",
            detail: message,
            operationID: id,
            requestsSystemDelivery: false
        ))
    }

    func cancel() { center.activities.cancel(id) }

    private func publish() {
        let status = lastError.map { "\(detail) · Error: \($0)" } ?? detail
        // The agent discovers work as it goes. Count completed operations and one outstanding
        // turn; elapsed time and streamed tokens never advance the progress counter.
        center.activities.update(id, detail: status, completed: completedSteps, total: completedSteps + 1)
    }
}
