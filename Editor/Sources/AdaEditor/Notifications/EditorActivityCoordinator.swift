import Foundation
import Observation

@MainActor
protocol EditorBackgroundExecution: AnyObject {
    func update(_ activity: EditorOperationActivity)
    func finish(success: Bool)
}

@Observable
@MainActor
final class EditorActivityCoordinator {
    private(set) var all: [EditorOperationActivity] = []
    @ObservationIgnored
    private weak var center: EditorNotificationCenter?
    @ObservationIgnored
    private var cancellations: [String: () -> Void] = [:]
    @ObservationIgnored
    private var backgrounds: [String: any EditorBackgroundExecution] = [:]

    init(center: EditorNotificationCenter) { self.center = center }
    var active: [EditorOperationActivity] { all.filter { !$0.state.isTerminal } }
    func canCancel(_ id: String) -> Bool { cancellations[id] != nil }

    func restore(_ saved: [EditorOperationActivity]) {
        let ids = Set(all.map(\.id))
        all += saved.filter { !ids.contains($0.id) }
            .map { item in
                var item = item
                if !item.state.isTerminal {
                    item.state = .interrupted
                    item.detail = "Interrupted when the application exited."
                }
                return item
            }
        all = Array(all.prefix(500))
    }

    @discardableResult
    func begin(_ activity: EditorOperationActivity, cancel: (() -> Void)? = nil) -> String {
        guard !all.contains(where: { $0.id == activity.id }) else {
            return activity.id
        }
        all.insert(activity, at: 0)
        cancellations[activity.id] = cancel
        trim()
        center?.persist()
        return activity.id
    }

    func attachBackground(_ background: any EditorBackgroundExecution, to id: String) {
        guard let activity = all.first(where: { $0.id == id }), activity.state == .running else {
            background.finish(success: false)
            return
        }
        backgrounds[id] = background
        background.update(activity)
    }

    func update(_ id: String, detail: String, completed: Int64? = nil, total: Int64? = nil, backgroundStatus: String? = nil) {
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].state.isTerminal else {
            return
        }
        all[index].detail = detail
        if let completed, let total, total > 0 {
            all[index].completedUnits = max(0, min(completed, total))
            all[index].totalUnits = total
        }
        if let backgroundStatus {
            all[index].backgroundStatus = backgroundStatus
        }
        backgrounds[id]?.update(all[index])
        center?.persist()
    }

    func setAction(_ action: EditorNotificationAction, for id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].state.isTerminal else {
            return
        }
        all[index].action = action
        backgrounds[id]?.update(all[index])
        center?.persist()
    }

    func needsAttention(_ id: String, detail: String, eventID: String) {
        guard let index = all.firstIndex(where: { $0.id == id }), !all[index].state.isTerminal else {
            return
        }
        all[index].state = .needsAttention
        all[index].detail = detail
        backgrounds.removeValue(forKey: id)?.finish(success: false)
        let item = all[index]
        center?
            .post(
                .init(
                    id: eventID,
                    source: item.source,
                    importance: .attention,
                    title: "Action required",
                    detail: detail,
                    projectName: item.projectName,
                    operationID: id,
                    actions: item.action.map { [$0] } ?? []
                )
            )
        center?.persist()
    }

    func resume(_ id: String) {
        guard let index = all.firstIndex(where: { $0.id == id }), all[index].state == .needsAttention else {
            return
        }
        all[index].state = .running
        all[index].detail = "Running"
        resolveAttention(id)
        center?.persist()
    }

    func finish(_ id: String, state: EditorOperationActivity.State, detail: String = "") {
        guard state.isTerminal, let index = all.firstIndex(where: { $0.id == id }), !all[index].state.isTerminal else {
            return
        }
        all[index].state = state
        all[index].detail = detail
        cancellations.removeValue(forKey: id)
        backgrounds.removeValue(forKey: id)?.finish(success: state == .completed)
        resolveAttention(id)
        let item = all[index]
        if item.source != .agent || state != .completed {
            center?
                .post(
                    .init(
                        id: "\(id):result",
                        source: item.source,
                        importance: state == .failed || state == .interrupted ? .error : (state == .cancelled ? .information : .success),
                        title: "\(item.title) — \(state.rawValue)",
                        detail: String(detail.prefix(600)),
                        projectName: item.projectName,
                        operationID: id,
                        actions: item.action.map { [$0] } ?? [],
                        requestsSystemDelivery: state != .cancelled && (item.source == .agent || item.source == .build || item.source == .test || state == .failed)
                    )
                )
        }
        trim()
        center?.persist()
    }

    func cancel(_ id: String, interrupted: Bool = false) {
        guard let cancel = cancellations[id] else {
            return
        }
        cancel()
        finish(id, state: interrupted ? .interrupted : .cancelled)
    }

    private func resolveAttention(_ id: String) {
        for item in center?.notifications ?? [] where item.operationID == id && item.importance == .attention {
            center?.dismiss(item.id)
        }
    }

    private func trim() {
        let activeIDs = Set(active.map(\.id))
        var terminalCount = 0
        all = all.filter { item in
            if activeIDs.contains(item.id) {
                return true
            }
            terminalCount += 1
            return terminalCount <= max(0, 500 - activeIDs.count)
        }
    }
}
