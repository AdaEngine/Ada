import Foundation

#if os(macOS)
    import AppKit
#elseif os(iOS)
    import UIKit
#endif
#if os(macOS) || os(iOS)
    import UserNotifications

    @MainActor
    final class EditorSystemNotifications: NSObject, UNUserNotificationCenterDelegate {
        static let shared = EditorSystemNotifications()
        private lazy var system = UNUserNotificationCenter.current()
        private var installed = false

        func install(on center: EditorNotificationCenter) {
            guard !installed else {
                return
            }
            guard Bundle.main.bundleURL.pathExtension == "app" else {
                center.authorizationStatus = "System notifications require the packaged AdaEditor application."
                return
            }
            installed = true
            system.delegate = self
            let open = UNNotificationAction(identifier: "open", title: "Open in AdaEditor", options: .foreground)
            system.setNotificationCategories([UNNotificationCategory(identifier: "editor.event", actions: [open], intentIdentifiers: [])])
            center.applicationIsActive = {
                #if os(macOS)
                    NSApplication.shared.isActive
                #else
                    UIApplication.shared.applicationState == .active
                #endif
            }
            center.requestAuthorization = { [weak self] in
                guard let self else {
                    return false
                }
                do { return try await system.requestAuthorization(options: [.alert, .badge, .sound]) } catch {
                    center.authorizationStatus = error.localizedDescription
                    return false
                }
            }
            center.deliver = { [weak self] item, sound in self?.deliver(item, sound: sound, center: center) }
            center.removeDelivered = { [weak self] ids in
                self?.system.removeDeliveredNotifications(withIdentifiers: ids)
                self?.system.removePendingNotificationRequests(withIdentifiers: ids)
            }
            Task {
                let settings = await system.notificationSettings()
                center.authorizationStatus =
                    settings.authorizationStatus == .authorized
                    ? "System permission granted." : "Enable system notifications to request permission."
            }
        }

        private func deliver(_ item: EditorNotification, sound: Bool, center: EditorNotificationCenter) {
            let content = UNMutableNotificationContent()
            content.title = item.title
            content.subtitle = item.projectName ?? item.source.rawValue
            content.body = item.detail
            content.categoryIdentifier = "editor.event"
            content.threadIdentifier = item.actions.first?.projectID ?? "AdaEditor"
            if sound {
                content.sound = .default
            }
            if let action = item.actions.first, let data = try? JSONEncoder().encode(action), let value = String(bytes: data, encoding: .utf8) {
                content.userInfo["action"] = value
            }
            Task {
                do { try await system.add(UNNotificationRequest(identifier: item.id, content: content, trigger: nil)) } catch {
                    center.authorizationStatus = "Notification delivery failed: \(error.localizedDescription)"
                }
            }
        }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification
        ) async -> UNNotificationPresentationOptions { [] }

        nonisolated func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse
        ) async {
            guard response.actionIdentifier != UNNotificationDismissActionIdentifier else {
                return
            }
            let id = response.notification.request.identifier
            let value = response.notification.request.content.userInfo["action"] as? String
            let action = value.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONDecoder().decode(EditorNotificationAction.self, from: $0) }
            await MainActor.run {
                EditorNotificationCenter.shared.dismiss(id)
                if let action {
                    EditorNotificationCenter.shared.perform(action)
                }
            }
        }
    }
#endif
