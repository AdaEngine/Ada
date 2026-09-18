import Foundation
import Observation

@Observable
@MainActor
final class EditorNotificationCenter {
    static let shared = EditorNotificationCenter(
        store: EditorNotificationStore(
            url: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AdaEditor/notifications.json")
        )
    )

    private(set) var notifications: [EditorNotification] = []
    private(set) var toastIDs: [String] = []
    var preferences = EditorNotificationPreferences()
    var storageError: String?
    var authorizationStatus = "System notifications are off."
    @ObservationIgnored
    lazy var activities = EditorActivityCoordinator(center: self)
    @ObservationIgnored
    var deliver: ((EditorNotification, Bool) -> Void)?
    @ObservationIgnored
    var removeDelivered: (([String]) -> Void)?
    @ObservationIgnored
    var requestAuthorization: (() async -> Bool)?
    @ObservationIgnored
    var applicationIsActive: () -> Bool = { true }
    @ObservationIgnored
    var onAction: ((EditorNotificationAction) -> Void)?
    @ObservationIgnored
    private let store: EditorNotificationStore?
    @ObservationIgnored
    private var revision = 0
    @ObservationIgnored
    private var persistenceAvailable = true
    @ObservationIgnored
    private var loaded = false
    @ObservationIgnored
    private var pendingReadIDs: Set<String> = []
    @ObservationIgnored
    private var clearedBeforeLoad = false
    @ObservationIgnored
    private var isLoading = false
    @ObservationIgnored
    private var deadlines: [String: Date] = [:]
    @ObservationIgnored
    private var paused: Set<String> = []
    @ObservationIgnored
    private var panelOwners: Set<UUID> = []
    @ObservationIgnored
    private var timer: Task<Void, Never>?

    init(store: EditorNotificationStore? = nil) { self.store = store }

    static let toastLifetime: TimeInterval = 4

    var unreadCount: Int { notifications.filter { !$0.isRead }.count }
    var toasts: [EditorNotification] {
        toastIDs.prefix(3).compactMap { id in notifications.first { $0.id == id } }
    }

    func start() async {
        guard !loaded, !isLoading else {
            return
        }
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await store?.load() ?? .init()
            let existingIDs = Set(notifications.map(\.id))
            notifications = Array(
                (notifications + (clearedBeforeLoad ? [] : snapshot.notifications.filter { !existingIDs.contains($0.id) }))
                    .sorted { $0.createdAt > $1.createdAt }.prefix(500)
            )
            for index in notifications.indices where pendingReadIDs.contains(notifications[index].id) {
                notifications[index].isRead = true
            }
            pendingReadIDs.removeAll()
            preferences = snapshot.preferences
            activities.restore(snapshot.activities)
            for activity in snapshot.activities where !activity.state.isTerminal && !activities.active.contains(where: { $0.id == activity.id }) {
                post(
                    .init(
                        id: "\(activity.id):result",
                        source: activity.source,
                        importance: .warning,
                        title: "\(activity.title) — interrupted",
                        detail: "The application exited before this operation finished.",
                        projectName: activity.projectName,
                        operationID: activity.id,
                        actions: activity.action.map { [$0] } ?? [],
                        requestsSystemDelivery: false
                    )
                )
            }
        } catch {
            persistenceAvailable = false
            storageError = "Unable to load notifications: \(error.localizedDescription)"
        }
        loaded = true
        persist()
        timer = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                self?.expireToasts()
            }
        }
    }

    func post(_ notification: EditorNotification) {
        if let index = notifications.firstIndex(where: { $0.id == notification.id }) {
            let read = notifications[index].isRead
            notifications[index] = notification
            notifications[index].isRead = read
        } else {
            notifications.insert(notification, at: 0)
            toastIDs.insert(notification.id, at: 0)
            // Queued cards get their four seconds only once they become visible.
            if preferences.shouldDeliver(notification, applicationIsActive: applicationIsActive()) {
                deliver?(notification, preferences.soundEnabled)
            }
        }
        notifications = Array(notifications.prefix(500))
        let ids = Set(notifications.map(\.id))
        toastIDs.removeAll { !ids.contains($0) }
        expireToasts()
        persist()
    }

    func expireToasts(now: Date = Date()) {
        let visibleToasts = toasts
        let visibleIDs = Set(visibleToasts.map(\.id))
        deadlines = deadlines.filter { visibleIDs.contains($0.key) }
        for item in visibleToasts where !item.importance.isPersistent {
            if paused.contains(item.id) || !panelOwners.isEmpty {
                deadlines[item.id] = now.addingTimeInterval(Self.toastLifetime)
            } else if let deadline = deadlines[item.id] {
                if deadline <= now {
                    hideToast(item.id)
                }
            } else {
                deadlines[item.id] = now.addingTimeInterval(Self.toastLifetime)
            }
        }
    }

    func setHovered(_ id: String, _ value: Bool) {
        if value {
            paused.insert(id)
        } else {
            paused.remove(id)
        }
    }

    func setPanelVisible(_ visible: Bool, owner: UUID) {
        if visible {
            panelOwners.insert(owner)
        } else {
            panelOwners.remove(owner)
        }
    }

    func hideToast(_ id: String) {
        toastIDs.removeAll { $0 == id }
        deadlines.removeValue(forKey: id)
        paused.remove(id)
    }

    func dismiss(_ id: String) {
        hideToast(id)
        markRead(id)
    }

    func markRead(_ id: String) {
        if !loaded {
            pendingReadIDs.insert(id)
        }
        if let index = notifications.firstIndex(where: { $0.id == id }) {
            notifications[index].isRead = true
        }
        removeDelivered?([id])
        persist()
    }

    func markAllRead() {
        for index in notifications.indices { notifications[index].isRead = true }
        removeDelivered?(notifications.map(\.id))
        persist()
    }

    func clear() {
        if !loaded {
            clearedBeforeLoad = true
        }
        removeDelivered?(notifications.map(\.id))
        notifications.removeAll()
        toastIDs.removeAll()
        deadlines.removeAll()
        paused.removeAll()
        persist()
    }

    func perform(_ action: EditorNotificationAction, notificationID: String? = nil) {
        if let notificationID {
            dismiss(notificationID)
        }
        onAction?(action)
    }

    func setSystemEnabled(_ enabled: Bool) async {
        if enabled {
            let granted = await requestAuthorization?() ?? false
            preferences.systemEnabled = granted
            authorizationStatus = granted ? "System notifications enabled." : "Permission unavailable. Enable notifications in system settings."
        } else {
            preferences.systemEnabled = false
            authorizationStatus = "System notifications are off."
        }
        persist()
    }

    func persist() {
        guard loaded, persistenceAvailable, let store else {
            return
        }
        revision += 1
        let revision = revision
        let snapshot = EditorNotificationSnapshot(notifications: notifications, activities: activities.all, preferences: preferences)
        Task {
            do { try await store.save(snapshot, revision: revision) } catch { storageError = "Unable to save notifications: \(error.localizedDescription)" }
        }
    }
}
