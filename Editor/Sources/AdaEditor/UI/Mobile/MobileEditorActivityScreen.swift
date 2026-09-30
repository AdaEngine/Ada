#if os(iOS)
    import AdaEngine
    import Foundation

    struct MobileEditorActivityScreen: View {
        var center = EditorNotificationCenter.shared
        @State private var now = Date()
        @Environment(\.theme) private var theme

        var body: some View {
            ScrollView(showsIndicators: true) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(center.activities.all.prefix(20)) { activity in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(activity.title).font(.system(size: 16, weight: .semibold))
                            Text(activity.systemSubtitle(at: now)).font(.system(size: 13))
                            if let status = activity.backgroundStatus {
                                Text(status).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                            }
                            if center.activities.canCancel(activity.id) {
                                Button("Stop agent") { center.activities.cancel(activity.id) }
                                    .accessibilityIdentifier("AdaEditor.Mobile.Activity.Stop.\(activity.id)")
                            }
                        }
                        .padding(.all, 14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surface))
                    }
                    Text("Notifications").font(.system(size: 18, weight: .semibold))
                    ForEach(center.notifications) { item in
                        EditorNotificationCard(item: item, center: center)
                    }
                    EditorNotificationSettings(center: center)
                }
                .padding(.all, 16)
            }
            .foregroundColor(theme.editorColors.text)
            .background(theme.editorColors.background.ignoresSafeArea())
            .accessibilityIdentifier("AdaEditor.Mobile.Activity")
            .task { @MainActor in
                while !Task.isCancelled {
                    now = Date()
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                }
            }
        }
    }
#endif
