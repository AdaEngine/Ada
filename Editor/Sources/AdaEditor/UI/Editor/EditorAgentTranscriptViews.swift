@_spi(AdaEngine) import AdaEngine
import Math

/// Measure height at the final bubble width; HStack's ideal-width height can clip wrapped replies.
private struct EditorAgentMessageRowLayout: Layout {
    let isUser: Bool

    func sizeThatFits(_ proposal: ProposedViewSize, subviews: Subviews, cache _: inout Void) -> Size {
        guard let card = subviews.first else {
            return .zero
        }
        let width = proposal.width.map { max(0, $0 - (isUser ? 40 : 0)) }
        var cardProposal = ProposedViewSize.unspecified
        cardProposal.width = width
        let size = card.sizeThatFits(cardProposal)
        return Size(width: proposal.width ?? size.width, height: size.height)
    }

    func placeSubviews(in bounds: Rect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout Void) {
        guard let card = subviews.first else {
            return
        }
        let available = max(0, bounds.width - (isUser ? 40 : 0))
        var cardProposal = ProposedViewSize.unspecified
        cardProposal.width = available
        let size = card.sizeThatFits(cardProposal)
        cardProposal.width = min(size.width, available)
        cardProposal.height = size.height
        card.place(
            at: Point(isUser ? bounds.maxX : bounds.minX, bounds.minY),
            anchor: isUser ? .topTrailing : .topLeading,
            proposal: cardProposal
        )
    }
}

struct EditorAgentEventCard: View {
    let event: EditorAgentEvent
    let viewModel: EditorAgentViewModel

    @Environment(\.theme) private var theme

    @State private var isExpanded = false

    private var isUser: Bool { event.message?.role == .user }
    private var isCollapsible: Bool {
        event.kind == .runStatus || event.toolCall != nil
            || event.message?.segments.allSatisfy { $0.kind == .thinking } == true
    }

    var body: some View {
        EditorAgentMessageRowLayout(isUser: isUser) {
            cardContent
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
        .accessibilityIdentifier("AdaEditor.Agent.Event.\(event.id)")
    }

    private var cardContent: some View {
        VStack(alignment: .leading, spacing: 5) {
            if isCollapsible {
                Button(action: { isExpanded.toggle() }) {
                    HStack(spacing: 5) {
                        Text(isExpanded ? "\u{E5CF}" : "\u{E5CC}")
                            .font(AdaEditorMaterialSymbolFont.font(size: 15))
                        Text(event.message == nil ? eventTitle : "Thinking")
                            .font(.system(size: 10, weight: .semibold))
                            .lineLimit(1)
                        Spacer()
                    }
                    .foregroundColor(eventColor)
                    .frame(height: 24)
                }
                .buttonStyle(DefaultButtonStyle())
                .accessibilityIdentifier("AdaEditor.Agent.ToggleEvent.\(event.id)")
            }
            if !isCollapsible || isExpanded {
                eventContent
            }
        }
        .padding(isUser || isCollapsible ? 8 : 0)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(eventBackground))
        .accessibilityIdentifier("AdaEditor.Agent.EventContent.\(event.id)")
    }

    @ViewBuilder
    private var eventContent: some View {
        if let toolCall = event.toolCall {
            toolCallView(toolCall)
        } else if let permission = event.permission {
            permissionView(permission)
        } else if event.message == nil && !isCollapsible {
            Text(eventTitle)
                .font(.system(size: 12))
                .foregroundColor(eventColor)
        }
        if let message = event.message {
            ForEach(Array(message.segments.enumerated()), id: \.offset) { _, segment in
                segmentView(segment)
            }
        } else if event.toolCall == nil, event.permission == nil, let details = event.details {
            Text(details)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
        }
    }

    @ViewBuilder
    private func segmentView(_ segment: EditorAgentMessageSegment) -> some View {
        switch segment.kind {
        case .text:
            if let failure = EditorAgentProviderFailure.message(in: segment.text ?? "") {
                Text(verbatim: failure)
                    .font(.system(size: 14))
                    .foregroundColor(.red)
            } else {
                Text(markdown: segment.text ?? "")
                    .font(.system(size: 14))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .thinking:
            Text(markdown: segment.text ?? "")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
        case .attachment:
            if let attachment = segment.attachment {
                EditorAgentAttachmentCard(attachment: attachment)
            }
        case .skill:
            Text("/\(segment.skill?.name ?? "skill")")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.purple)
                .lineLimit(1)
        }
    }

    private func toolCallView(_ toolCall: EditorAgentToolCall) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(toolCall.kind.uppercased())
                    .font(.system(size: 9))
                    .foregroundColor(theme.editorColors.blue)
                    .padding(.horizontal, 6)
                    .frame(height: 20)
                    .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.blue.opacity(0.12)))
                Text(toolCall.title)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Spacer()
                Text(toolStatusTitle(toolCall.status))
                    .font(.system(size: 9))
                    .foregroundColor(toolStatusColor(toolCall.status))
            }
            ForEach(Array(toolCall.locations.enumerated()), id: \.offset) { _, location in
                Text(toolLocationTitle(location))
                    .font(.system(size: 9))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            ForEach(Array(toolCall.content.enumerated()), id: \.offset) { _, content in
                toolContentView(content)
            }
        }
    }

    @ViewBuilder
    private func toolContentView(_ content: EditorAgentToolContent) -> some View {
        switch content.kind {
        case .text:
            Text(markdown: content.text ?? "")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(10)
        case .diff:
            VStack(alignment: .leading, spacing: 3) {
                Text(content.path ?? "Modified file")
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.blue)
                    .lineLimit(1)
                if let newText = content.newText, !newText.isEmpty {
                    Text(verbatim: newText)
                        .font(.system(size: 9))
                        .foregroundColor(theme.editorColors.muted)
                        .lineLimit(8)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.background))
        case .terminal:
            Text("Terminal · \(content.terminalID ?? "running")")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.muted)
        case .image:
            Text("Image output · \(content.mimeType ?? "image")")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.blue)
        case .resource:
            Text(content.text ?? content.uri ?? "Resource")
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.blue)
                .lineLimit(3)
        }
    }

    private func permissionView(_ permission: EditorAgentPermissionRequest) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(permission.state == .pending ? "APPROVAL REQUIRED" : "APPROVAL")
                    .font(.system(size: 9))
                    .foregroundColor(permission.state == .pending ? theme.editorColors.purple : theme.editorColors.muted)
                Spacer()
                if permission.state != .pending {
                    Text(permission.state == .selected ? "Resolved" : "Cancelled")
                        .font(.system(size: 9))
                        .foregroundColor(theme.editorColors.muted)
                }
            }
            Text(markdown: permission.summary)
                .font(.system(size: 12))
                .foregroundColor(theme.editorColors.text)
            if permission.state == .pending {
                HStack(spacing: 6) {
                    ForEach(permission.options, id: \.id) { option in
                        Button(action: { viewModel.resolvePermission(requestID: permission.id, optionID: option.id) }) {
                            Text(option.name)
                                .font(.system(size: 12))
                                .foregroundColor(theme.editorColors.text)
                                .padding(.horizontal, 9)
                                .frame(height: 25)
                                .background(RoundedRectangleShape(cornerRadius: 5).fill(permissionOptionColor(option).opacity(0.20)))
                        }
                        .buttonStyle(DefaultButtonStyle())
                    }
                    Button(action: { viewModel.resolvePermission(requestID: permission.id, optionID: nil) }) {
                        Text("Cancel")
                            .font(.system(size: 12))
                            .foregroundColor(theme.editorColors.muted)
                            .padding(.horizontal, 9)
                            .frame(height: 25)
                    }
                    .buttonStyle(DefaultButtonStyle())
                }
            }
        }
        .accessibilityIdentifier("AdaEditor.Agent.Permission.\(permission.id)")
    }

    private var eventTitle: String {
        event.title ?? event.message?.role.rawValue.uppercased() ?? event.kind.rawValue
    }

    private var eventColor: Color {
        switch event.kind {
        case .error:
            theme.editorColors.purple
        case .toolCall,
            .toolResult,
            .permission:
            theme.editorColors.blue
        case .message,
            .runStatus:
            theme.editorColors.muted
        }
    }

    private var eventBackground: Color {
        isUser ? theme.editorColors.blue.opacity(0.14) : (isCollapsible ? theme.editorColors.surface : .clear)
    }

    private func toolStatusTitle(_ status: EditorAgentToolStatus?) -> String {
        switch status {
        case .pending,
            nil:
            "Pending"
        case .inProgress: "Running"
        case .completed: "Done"
        case .failed: "Failed"
        }
    }

    private func toolStatusColor(_ status: EditorAgentToolStatus?) -> Color {
        switch status {
        case .completed: theme.editorColors.blue
        case .failed: theme.editorColors.purple
        case .pending,
            .inProgress,
            nil:
            theme.editorColors.muted
        }
    }

    private func toolLocationTitle(_ location: EditorAgentToolLocation) -> String {
        let path = location.path ?? "Project"
        return location.line.map { "\(path):\($0)" } ?? path
    }

    private func permissionOptionColor(_ option: EditorAgentPermissionOption) -> Color {
        option.kind.hasPrefix("allow") ? theme.editorColors.blue : theme.editorColors.purple
    }
}

struct EditorAgentAttachmentCard: View {
    let attachment: EditorAgentAttachment
    var onRemove: (() -> Void)?

    @Environment(\.theme) private var theme

    init(attachment: EditorAgentAttachment, onRemove: (() -> Void)? = nil) {
        self.attachment = attachment
        self.onRemove = onRemove
    }

    var body: some View {
        HStack(spacing: 7) {
            preview
            VStack(alignment: .leading, spacing: 2) {
                Text(attachment.name)
                    .font(.system(size: 12))
                    .foregroundColor(theme.editorColors.text)
                    .lineLimit(1)
                Text(description)
                    .font(.system(size: 9))
                    .foregroundColor(theme.editorColors.muted)
                    .lineLimit(1)
            }
            if let onRemove {
                Button(action: onRemove) {
                    Text("×")
                        .font(.system(size: 11))
                        .foregroundColor(theme.editorColors.muted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(DefaultButtonStyle())
            }
        }
        .padding(6)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
        .overlay {
            RoundedRectangleShape(cornerRadius: 6)
                .stroke(theme.editorColors.border.opacity(0.35), lineWidth: 1)
        }
    }

    @ViewBuilder
    private var preview: some View {
        if attachment.mimeType.hasPrefix("image/"),
            let image = try? Image(contentsOf: URL(fileURLWithPath: attachment.absolutePath, isDirectory: false)) {
            image
                .resizable()
                .aspectRatio(Float(image.width) / Float(max(1, image.height)), contentMode: .fit)
                .frame(width: 36, height: 36)
                .mask(RoundedRectangleShape(cornerRadius: 4))
        } else {
            Text(fileLabel)
                .font(.system(size: 9))
                .foregroundColor(theme.editorColors.blue)
                .frame(width: 28, height: 28)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.blue.opacity(0.10)))
        }
    }

    private var fileLabel: String {
        let fileExtension = URL(fileURLWithPath: attachment.name).pathExtension.uppercased()
        if ["PNG", "JPG", "JPEG", "GIF"].contains(fileExtension) {
            return "IMG"
        }
        return fileExtension.isEmpty ? "FILE" : String(fileExtension.prefix(4))
    }

    private var description: String {
        let kind = attachment.mimeType.hasPrefix("image/") ? "Image" : "File"
        guard let sizeBytes = attachment.sizeBytes else {
            return kind
        }
        if sizeBytes >= 1_048_576 {
            return "\(kind) · \(sizeBytes / 1_048_576) MB"
        }
        if sizeBytes >= 1_024 {
            return "\(kind) · \(sizeBytes / 1_024) KB"
        }
        return "\(kind) · \(sizeBytes) B"
    }
}
