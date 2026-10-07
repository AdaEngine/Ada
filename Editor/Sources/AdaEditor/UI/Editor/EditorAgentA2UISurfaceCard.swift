import AdaA2UI
@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorAgentA2UISurfaceCard: View {
    let viewModel: EditorAgentViewModel
    let session: EditorAgentA2UISession
    let surfaceID: String
    @Environment(\.theme) private var theme

    private var record: EditorAgentA2UISurfaceRecord? { session.records[surfaceID] }
    private var canInteract: Bool {
        record?.state == .ready && !viewModel.isSending && !viewModel.isSubmittingA2UI && viewModel.agentEnabled
            && record?.agentIdentity == viewModel.settings.configuration.target.sessionIdentity
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(surfaceID.replacingOccurrences(of: "-", with: " ").capitalized)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Text(stateTitle).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            }
            A2UISurfaceView(client: session.client, surfaceID: surfaceID)
                .font(.system(size: 14))
                .frame(maxWidth: .infinity, alignment: .leading)
                .textFieldStyle(EditorAgentA2UIFieldStyle())
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: true, bordered: true))
                .disabled(!canInteract)
            if let error = record?.error {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            }
            Button("Open in UI Designer") { viewModel.openA2UIPreview(surfaceID: surfaceID) }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
                .disabled(viewModel.isSending || session.client.surfaces[surfaceID]?.scene.document.root.type == "EmptyView")
                .accessibilityIdentifier("AdaEditor.Agent.A2UI.OpenDesigner.\(surfaceID)")
        }
        .foregroundColor(theme.editorColors.text)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surface))
        .accessibilityIdentifier("AdaEditor.Agent.A2UI.Surface.\(surfaceID)")
    }

    private var stateTitle: String {
        if record?.agentIdentity != viewModel.settings.configuration.target.sessionIdentity {
            return "Reconnect the original agent"
        }
        switch record?.state {
        case .receiving: return "Preparing form…"
        case .ready: return viewModel.isSending ? "Agent is working…" : "Ready"
        case .submitting: return "Submitting…"
        case .submitted: return "Submitted"
        case .cancelled: return "Interrupted"
        case .failed: return "Agent failed"
        case nil: return "Unavailable"
        }
    }
}

private struct EditorAgentA2UIFieldStyle: TextFieldStyle {
    @Environment(\.theme) private var theme
    func _body(configuration: TextField) -> some View {
        PlainTextFieldStyle()._body(configuration: configuration)
            .padding(.horizontal, 8)
            .background(theme.editorColors.background)
            .border(theme.editorColors.border, lineWidth: 1)
    }
}
