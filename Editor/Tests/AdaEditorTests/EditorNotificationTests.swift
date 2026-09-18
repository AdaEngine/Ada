import Foundation
import Testing

@testable import AdaEditor

@Suite("Editor notifications", .serialized)
@MainActor
struct EditorNotificationTests {
    @Test("Agent success stays in activity history without adding a notification")
    func agentSuccessIsQuiet() {
        let center = EditorNotificationCenter()
        center.preferences.systemEnabled = true
        center.applicationIsActive = { false }
        var deliveries = 0
        center.deliver = { _, _ in deliveries += 1 }
        let agent = center.activities.begin(.init(source: .agent, title: "Codex"))
        center.activities.finish(agent, state: .completed)
        #expect(center.activities.all.first?.state == .completed)
        #expect(center.notifications.isEmpty)
        #expect(center.toasts.isEmpty)
        #expect(center.unreadCount == 0)
        #expect(deliveries == 0)

        let failed = center.activities.begin(.init(source: .agent, title: "Codex"))
        center.activities.finish(failed, state: .failed, detail: "Connection failed")
        #expect(center.notifications.contains { $0.operationID == failed && $0.importance == .error })
        let build = center.activities.begin(.init(source: .build, title: "Build"))
        center.activities.finish(build, state: .completed)
        #expect(center.notifications.contains { $0.operationID == build && $0.importance == .success })
    }

    @Test("Duplicate events deliver once; closing preserves read history")
    func deduplication() {
        let center = EditorNotificationCenter()
        center.preferences.systemEnabled = true
        center.applicationIsActive = { false }
        var deliveries = 0
        center.deliver = { _, _ in deliveries += 1 }
        let item = EditorNotification(id: "run:done", source: .agent, importance: .success, title: "Done")
        center.post(item)
        center.post(item)
        #expect(deliveries == 1)
        #expect(center.notifications.count == 1)
        center.dismiss(item.id)
        #expect(center.unreadCount == 0)
        #expect(center.toasts.isEmpty)
        #expect(center.notifications.count == 1)
        center.post(item)
        #expect(center.unreadCount == 0)
        #expect(deliveries == 1)
    }

    @Test("Only three cards are visible; attention persists and interaction pauses expiry")
    func toastLifetime() {
        let center = EditorNotificationCenter()
        let now = Date()
        for index in 0..<4 {
            center.post(.init(id: "\(index)", source: .agent, importance: index == 3 ? .attention : .information, title: "Event"))
        }
        #expect(center.toasts.map(\.id) == ["3", "2", "1"])
        center.setHovered("2", true)
        center.expireToasts(now: now.addingTimeInterval(20))
        #expect(center.toastIDs.contains("3"))
        #expect(center.toastIDs.contains("2"))
        #expect(!center.toastIDs.contains("1"))
        #expect(center.toastIDs.contains("0"))
        center.setHovered("2", false)
        center.expireToasts(now: now.addingTimeInterval(29))
        #expect(!center.toastIDs.contains("2"))
        #expect(center.unreadCount == 4)
    }

    @Test("informational and success toasts expire in four seconds, errors remain in view")
    func fourSecondExpiry() {
        let center = EditorNotificationCenter()
        center.post(.init(id: "info", source: .project, importance: .information, title: "Information"))
        center.post(.init(id: "success", source: .build, importance: .success, title: "Built"))
        center.post(.init(id: "error", source: .build, importance: .error, title: "Failed"))
        let now = Date()
        center.expireToasts(now: now.addingTimeInterval(3.8))
        #expect(center.toastIDs.count == 3)
        center.expireToasts(now: now.addingTimeInterval(4.2))
        #expect(center.toastIDs == ["error"])
        #expect(center.notifications.count == 3)
        #expect(center.unreadCount == 3)
    }

    @Test("the running timer hides an info toast without user input")
    func runningExpiryTimer() async throws {
        let center = EditorNotificationCenter()
        await center.start()
        center.post(.init(id: "timer", source: .project, importance: .information, title: "Done"))
        try await Task.sleep(for: .seconds(4.5))
        #expect(center.toasts.isEmpty)
        #expect(center.notifications.count == 1)
    }

    @Test("Foreground and category settings suppress system delivery")
    func deliveryPolicy() {
        var preferences = EditorNotificationPreferences()
        let notification = EditorNotification(source: .build, importance: .success, title: "Built")
        #expect(!preferences.shouldDeliver(notification, applicationIsActive: false))
        preferences.systemEnabled = true
        #expect(!preferences.shouldDeliver(notification, applicationIsActive: true))
        #expect(preferences.shouldDeliver(notification, applicationIsActive: false))
        preferences.enabledSources.remove(.build)
        #expect(!preferences.shouldDeliver(notification, applicationIsActive: false))
    }

    @Test("History round trips through an actual file and stale writes are ignored")
    func persistence() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("EditorNotifications-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = EditorNotificationStore(url: root.appendingPathComponent("history.json"))
        let item = EditorNotification(
            id: "persisted",
            source: .agent,
            importance: .error,
            title: "Failed",
            actions: [.init(title: "Chat", destination: .chat, projectID: "project", sessionID: "session")]
        )
        try await store.save(.init(notifications: [item]), revision: 2)
        try await store.save(.init(), revision: 1)
        let restored = try await store.load()
        #expect(restored.notifications == [item])
        #expect(restored.notifications.first?.actions.first?.sessionID == "session")
    }

    @Test("History is bounded and clearing removes delivered system notifications")
    func historyLimit() {
        let center = EditorNotificationCenter()
        for index in 0..<510 { center.post(.init(id: "\(index)", source: .build, importance: .success, title: "Built")) }
        #expect(center.notifications.count == 500)
        #expect(center.notifications.last?.id == "10")
        var removed: [String] = []
        center.removeDelivered = { removed += $0 }
        center.clear()
        #expect(removed.count == 500)
        #expect(center.notifications.isEmpty)
        #expect(center.toastIDs.isEmpty)
    }

    @Test("Attention releases background execution; cancellation and late completion are idempotent")
    func activityLifecycle() {
        let center = EditorNotificationCenter()
        let coordinator = center.activities
        var cancelled = 0
        let id = coordinator.begin(.init(source: .agent, title: "Agent", completedUnits: 0, totalUnits: 4), cancel: { cancelled += 1 })
        let background = NotificationTestBackground()
        coordinator.attachBackground(background, to: id)
        coordinator.update(id, detail: "Tools", completed: 2, total: 4)
        #expect(coordinator.active.first?.fractionCompleted == 0.5)
        coordinator.needsAttention(id, detail: "Allow tool?", eventID: "permission")
        #expect(background.completions == [false])
        #expect(coordinator.active.first?.state == .needsAttention)
        coordinator.resume(id)
        #expect(center.notifications.first?.isRead == true)
        coordinator.cancel(id)
        coordinator.cancel(id)
        coordinator.finish(id, state: .completed)
        #expect(cancelled == 1)
        #expect(coordinator.all.first?.state == .cancelled)
        #expect(center.notifications.filter { $0.id == "\(id):result" }.count == 1)
        #expect(background.completions == [false])
    }

    @Test("Restoring never represents abandoned execution as running")
    func restoredActivity() {
        let center = EditorNotificationCenter()
        center.activities.restore([.init(source: .agent, title: "Old agent")])
        #expect(center.activities.active.isEmpty)
        #expect(center.activities.all.first?.state == .interrupted)
        #expect(center.activities.all.first?.fractionCompleted == nil)
    }

    @Test("Action uses the original project and session after being persisted")
    func actionRouting() throws {
        let center = EditorNotificationCenter()
        let action = EditorNotificationAction(title: "Open chat", destination: .chat, projectID: "original", sessionID: "one")
        let restored = try JSONDecoder().decode(EditorNotificationAction.self, from: JSONEncoder().encode(action))
        var received: EditorNotificationAction?
        center.onAction = { received = $0 }
        center.post(.init(id: "done", source: .agent, importance: .success, title: "Done", actions: [restored]))
        center.perform(restored, notificationID: "done")
        #expect(received == action)
        #expect(center.notifications.first?.isRead == true)
    }
}

@MainActor
private final class NotificationTestBackground: EditorBackgroundExecution {
    var completions: [Bool] = []
    func update(_: EditorOperationActivity) {}
    func finish(success: Bool) { completions.append(success) }
}
