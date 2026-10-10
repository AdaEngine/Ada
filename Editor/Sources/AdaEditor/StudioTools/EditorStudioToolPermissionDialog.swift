import AdaEngine
import AdaScriptCompilerCore
import Foundation

struct EditorStudioToolPermissionRequest: Identifiable, Hashable {
    enum Presentation { case workspace, settings }
    let id = UUID()
    let definition: EditorStudioToolDefinition
    let presentation: Presentation

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension AdaScriptToolPermission {
    var studioAccessTitle: String {
        switch self {
        case .documentRead: "Read open scenes"
        case .documentWrite: "Change open scenes"
        case .workspaceRead: "Read project files"
        case .workspaceWrite: "Change project files"
        case .clipboardRead: "Read the clipboard"
        case .clipboardWrite: "Write to the clipboard"
        case .network: "Access the network"
        case .process: "Run external processes"
        }
    }

    var studioAccessDetail: String {
        switch self {
        case .documentRead: "Read the active scene's path, revision and entity count."
        case .documentWrite: "Create entities in the active scene through its Undo history."
        default: "This capability is not available to Studio tools in this version."
        }
    }
}

struct EditorStudioToolPermissionDialog: View {
    let host: EditorStudioToolHost
    let request: EditorStudioToolPermissionRequest
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45)
                VStack(alignment: .leading, spacing: 16) {
                    Text("Allow \(request.definition.schema.name)?")
                        .font(.system(size: 20, weight: .semibold))
                    Text("This project tool will run inside Studio. Review its access before enabling it.")
                        .font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                    Text("\(request.definition.schema.id) · \(request.definition.schema.version)")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    if request.definition.schema.permissions.isEmpty {
                        Text("This tool requests no document access.").font(.system(size: 12))
                    }
                    ForEach(request.definition.schema.permissions, id: \.rawValue) { permission in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(permission.studioAccessTitle).font(.system(size: 13, weight: .semibold))
                            Text(permission.studioAccessDetail).font(.system(size: 12)).foregroundColor(theme.editorColors.muted)
                        }
                    }
                    Text("You can revoke access in Settings → Project → Studio Tools.")
                        .font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                    HStack {
                        Spacer()
                        Button("Not Now") { host.cancelPermissionRequest(request.id) }
                            .accessibilityIdentifier("studio.tools.permissions.cancel")
                        Button("Allow and Enable") { host.approve(request.id) }
                            .accessibilityIdentifier("studio.tools.permissions.allow")
                    }
                }
                .padding(24)
                .frame(width: min(500, max(0, geometry.size.width - 32)), alignment: .leading)
                .background(RoundedRectangleShape(cornerRadius: 12).fill(theme.editorColors.surfaceElevated))
                .foregroundColor(theme.editorColors.text)
                .accessibilityIdentifier("studio.tools.permissions.dialog")
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .keyboardShortcuts([KeyboardShortcutAction(.escape) { host.cancelPermissionRequest(request.id) }])
    }
}

struct EditorStudioToolPermissionPresentation: ViewModifier {
    let host: EditorStudioToolHost?
    let presentation: EditorStudioToolPermissionRequest.Presentation

    @ViewBuilder
    func body(content: Content) -> some View {
        if let host {
            content.fullScreenCover(
                item: Binding(
                    get: { host.permissionRequest?.presentation == presentation ? host.permissionRequest : nil },
                    set: { value in
                        if value == nil, let request = host.permissionRequest, request.presentation == presentation {
                            host.cancelPermissionRequest(request.id)
                        }
                    }
                )
            ) { request in
                EditorStudioToolPermissionDialog(host: host, request: request)
            }
        } else {
            content
        }
    }
}
