@_spi(AdaEngine) import AdaEngine
import Foundation

enum EditorNotificationTab { case notifications, activity }

struct EditorNotificationBell: View {
    let model: EditorViewModel
    var center = EditorNotificationCenter.shared

    var body: some View {
        Button {
            model.showsNotifications.toggle()
        } label: {
            Text("\u{E7F4}")
                .font(AdaEditorMaterialSymbolFont.font(size: 18))
                .foregroundColor(.white)
                .frame(width: 30, height: 24)
                .overlay(anchor: .topTrailing) {
                    if center.unreadCount > 0 {
                        RoundedRectangleShape(cornerRadius: 3.5).fill(Color(red: 0.95, green: 0.22, blue: 0.25))
                            .frame(width: 7, height: 7)
                            .accessibilityIdentifier("AdaEditor.Notifications.UnreadBadge")
                    }
                }
        }
        .buttonStyle(DefaultButtonStyle())
        .accessibilityIdentifier("AdaEditor.Notifications.Bell")
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
    }
}

struct EditorNotificationOverlay: View {
    let model: EditorViewModel
    let size: Size
    var center = EditorNotificationCenter.shared
    @State
    private var owner = UUID()
    @Environment(\.theme)
    private var theme

    private var width: Float { max(0, min(420, size.width - 24)) }
    private var height: Float { max(0, min(560, size.height - 64)) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 8) {
            if model.showsNotifications {
                panel
                    .frame(width: width, height: height)
                    .accessibilityIdentifier("AdaEditor.Notifications.Panel")
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(center.toasts) { item in
                            EditorNotificationCard(item: item, center: center)
                        }
                    }
                }
                .frame(width: width, height: min(height, Float(center.toasts.count) * 150))
            }
        }
        .padding(.trailing, 8)
        .padding(.bottom, 32)
        // Flush earlier panel geometry before drawing the notification surface.
        .drawingGroup()
        .onAppear { center.setPanelVisible(model.showsNotifications, owner: owner) }
        .onChange(of: model.showsNotifications) { _, visible in center.setPanelVisible(visible, owner: owner) }
        .onDisappear { center.setPanelVisible(false, owner: owner) }
    }

    private var displayedActivities: [EditorOperationActivity] {
        center.activities.active
            + model.activeActivities
            .filter {
                $0.kind != .agent && ($0.id != "workspace" || model.notificationWorkspaceRunID == nil)
            }
            .map { item in
                EditorOperationActivity(
                    id: "editor:\(item.id)",
                    source: .project,
                    title: item.title,
                    projectName: model.project?.name,
                    detail: item.detail ?? "Running",
                    completedUnits: item.fractionCompleted.map { Int64($0 * 1000) },
                    totalUnits: item.fractionCompleted == nil ? nil : 1000
                )
            }
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Button("Notifications (\(center.unreadCount))") { model.notificationTab = .notifications }
                    .foregroundColor(model.notificationTab == .notifications ? theme.editorColors.blue : theme.editorColors.text)
                Button("Activity (\(displayedActivities.count))") { model.notificationTab = .activity }
                    .foregroundColor(model.notificationTab == .activity ? theme.editorColors.blue : theme.editorColors.text)
                Spacer()
                Button("×") { model.showsNotifications = false }
            }
            .font(.system(size: 13))
            .foregroundColor(theme.editorColors.text)
            if let error = center.storageError {
                Text(error).foregroundColor(theme.editorColors.text).font(.system(size: 11))
            }
            ScrollView { eventList }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            if model.notificationTab == .notifications {
                HStack(spacing: 14) {
                    Button("Mark all read") { center.markAllRead() }
                    Button("Clear history") { center.clear() }
                    Spacer()
                    Button("Settings") { model.presentSettings(.notifications) }
                }
                .font(.system(size: 12))
            }
        }
        .padding(.all, 12)
        .foregroundColor(theme.editorColors.text)
        .background(RoundedRectangleShape(cornerRadius: 10).fill(theme.editorColors.background))
        .overlay { RoundedRectangleShape(cornerRadius: 10).stroke(theme.editorColors.border, lineWidth: 1) }
    }

    private var eventList: some View {
        VStack(alignment: .leading, spacing: 8) {
            if model.notificationTab == .notifications {
                if center.notifications.isEmpty {
                    Text("No notifications").padding(.all, 12)
                }
                ForEach(center.notifications) { item in EditorNotificationCard(item: item, center: center) }
            } else {
                if displayedActivities.isEmpty {
                    Text("No active work").padding(.all, 12)
                }
                ForEach(displayedActivities) { item in activityCard(item) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func activityCard(_ item: EditorOperationActivity) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.title).font(.system(size: 14))
            Text([item.projectName, item.state == .needsAttention ? "Needs attention" : item.detail].compactMap { $0 }.joined(separator: " · "))
                .font(.system(size: 12))
            if let fraction = item.fractionCompleted {
                Text("\(Int(fraction * 100))%").font(.system(size: 12))
            }
            if let status = item.backgroundStatus {
                Text(status).font(.system(size: 11))
            }
            HStack(spacing: 12) {
                if let action = item.action {
                    Button(action.title) { center.perform(action) }
                }
                if center.activities.canCancel(item.id) {
                    Button("Cancel") { center.activities.cancel(item.id) }
                }
            }
        }
        .padding(.all, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
    }
}

struct EditorNotificationCard: View {
    let item: EditorNotification
    let center: EditorNotificationCenter
    @Environment(\.theme)
    private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(item.importance == .error || item.importance == .warning ? "!" : "●")
                    .foregroundColor(item.importance.isPersistent ? Color.fromHex(0xEAB856) : theme.editorColors.blue)
                Text(item.source.rawValue + (item.isRead ? "" : " · New")).font(.system(size: 11))
                Spacer()
                Text(item.createdAt.formatted(date: .omitted, time: .shortened)).font(.system(size: 11))
                Button("×") { center.dismiss(item.id) }.accessibilityIdentifier("AdaEditor.Notification.Close.\(item.id)")
            }
            Text(item.title).font(.system(size: 14)).lineLimit(3)
            if let name = item.projectName {
                Text(name).font(.system(size: 11))
            }
            if !item.detail.isEmpty {
                Text(item.detail).font(.system(size: 12)).lineLimit(4)
            }
            HStack(spacing: 12) {
                ForEach(Array(item.actions.enumerated()), id: \.offset) { entry in
                    Button(entry.element.title) { center.perform(entry.element, notificationID: item.id) }
                        .accessibilityIdentifier("AdaEditor.Notification.Action.\(item.id).\(entry.offset)")
                }
                if !item.isRead {
                    Button("Mark read") { center.markRead(item.id) }
                }
            }
            .foregroundColor(theme.editorColors.blue)
            .font(.system(size: 12))
        }
        .foregroundColor(theme.editorColors.text)
        .padding(.all, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
        .onMiddleClick { center.dismiss(item.id) }
        .onHover { center.setHovered(item.id, $0) }
        .onDisappear { center.setHovered(item.id, false) }
        .accessibilityIdentifier("AdaEditor.Notification.\(item.id)")
    }
}

struct EditorNotificationSettings: View {
    var center = EditorNotificationCenter.shared
    @State private var isRequestingPermission = false
    @Environment(\.theme)
    private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("SYSTEM NOTIFICATIONS").font(.system(size: 14))
            #if DEBUG && os(iOS)
                if ProcessInfo.processInfo.environment["ADA_EDITOR_BACKGROUND_TEST"] == "1" {
                    Button("Run background diagnostic") { EditorBackgroundDiagnostic.shared.start() }
                        .accessibilityIdentifier("AdaEditor.Notifications.BackgroundDiagnostic")
                }
            #endif
            EditorSettingsToggleRow(title: "System notifications", isOn: center.preferences.systemEnabled) {
                isRequestingPermission = true
                Task {
                    await center.setSystemEnabled(!center.preferences.systemEnabled)
                    isRequestingPermission = false
                }
            }
            .disabled(isRequestingPermission)
            .accessibilityIdentifier("AdaEditor.Notifications.System")
            Text(center.authorizationStatus).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
            EditorSettingsToggleRow(title: "Sound", isOn: center.preferences.soundEnabled) {
                center.preferences.soundEnabled.toggle()
                center.persist()
            }
            .accessibilityIdentifier("AdaEditor.Notifications.Sound")
            Text("NOTIFICATION SOURCES").font(.system(size: 12, weight: .semibold)).padding(.top, 10)
            Text("Choose which events can send system notifications.")
                .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            VStack(spacing: 6) {
                ForEach(EditorNotificationSource.allCases, id: \.self) { source in
                    EditorSettingsToggleRow(title: source.rawValue, isOn: center.preferences.enabledSources.contains(source)) {
                        if !center.preferences.enabledSources.insert(source).inserted {
                            center.preferences.enabledSources.remove(source)
                        }
                        center.persist()
                    }
                    .accessibilityIdentifier("AdaEditor.Notifications.Source.\(source.rawValue)")
                }
            }
            Text("Results and requests for attention appear in the system while AdaEditor is inactive. Notification history is always available in the editor.")
                .font(.system(size: 12))
        }
        .foregroundColor(theme.editorColors.text)
    }
}
