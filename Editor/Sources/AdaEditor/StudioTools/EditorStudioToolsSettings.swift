import AdaEngine

struct EditorStudioToolsSettings: View {
    let host: EditorStudioToolHost
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(L10n.text("Access applies only to this project on this computer. Revoking it stops the tool and closes its panels."))
                .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
            if let error = host.error {
                Text(error).font(.system(size: 12)).foregroundColor(Color(red: 0.9, green: 0.3, blue: 0.2))
            }
            if host.definitions.isEmpty {
                Text(L10n.text("No tools found. Add tool folders under Tools/ in this project.")).font(.system(size: 12))
            }
            ForEach(host.definitions, id: \.schema.id) { definition in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(definition.schema.name).font(.system(size: 14, weight: .semibold))
                        Spacer()
                        if host.isAuthorized(definition) {
                            Button(L10n.text("Revoke Access")) { host.disable(definition.schema.id) }
                                .font(.system(size: 12))
                                .foregroundColor(Color(red: 232 / 255, green: 96 / 255, blue: 96 / 255))
                                .accessibilityIdentifier("studio.tools.revoke." + definition.schema.id)
                        } else {
                            Button(L10n.text("Enable…")) { host.enable(definition.schema.id, presentation: .settings) }
                                .disabled(host.unavailabilityReason(definition) != nil)
                                .accessibilityIdentifier("studio.tools.enable." + definition.schema.id)
                        }
                    }
                    Text("\(definition.schema.id) · \(definition.schema.version)")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    Text(host.isAuthorized(definition) ? L10n.text("Access allowed") : L10n.text("Access not allowed"))
                        .font(.system(size: 12))
                    ForEach(definition.schema.permissions, id: \.rawValue) { permission in
                        Text(L10n.tr(permission.studioAccessTitle)).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                    }
                    if let reason = host.unavailabilityReason(definition) {
                        Text(reason).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                    }
                }
                .padding(16)
                .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
            }
        }
        .accessibilityIdentifier("studio.tools.project-settings")
    }
}
