#if os(macOS) || os(Windows)
@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorSettingsWindowView {
    func localMCPSettings(_ settings: EditorLocalMCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            compactButton("Add MCP server") {
                viewModel.localMCPServer = settings.add()
                viewModel.localMCPToolDetails = nil
            }
            .disabled(settings.servers.count >= 12)
            .accessibilityIdentifier("AdaEditor.Settings.LocalMCP.Add")

            if let error = settings.storageError { localMCPNote(error) }
            if settings.servers.isEmpty { localMCPNote("Add a local MCP server to choose tools for Ada AI.") }
            let selected = settings.servers.first { $0.id == viewModel.localMCPServer } ?? settings.servers.first
            ForEach(settings.servers) { server in
                let name = server.name.isEmpty ? L10n.tr("New MCP server") : server.name
                selectionButton(name, selected: selected?.id == server.id, localizesTitle: false) {
                    viewModel.localMCPServer = server.id
                    viewModel.localMCPToolDetails = nil
                }
                .accessibilityIdentifier("AdaEditor.Settings.LocalMCP.Server.\(server.id.uuidString)")
            }
            if let selected { localMCPServerForm(selected, settings: settings) }
        }
    }

    private func localMCPServerForm(_ server: EditorLocalMCPSettings.Configuration, settings: EditorLocalMCPSettings) -> some View {
        let id = server.id
        let connection = settings.connections[id]
        let connecting = settings.connecting.contains(id)
        return VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                localMCPField("MCP server name", id: "Name", text: localMCPBinding(\.name, server: server, settings: settings))
                localMCPField("MCP executable path", id: "Executable", text: localMCPBinding(\.executable, server: server, settings: settings))

                Text(L10n.text("MCP arguments in launch order")).font(.system(size: 12)).foregroundColor(theme.editorColors.text)
                ForEach(Array(server.arguments.indices), id: \.self) { index in
                    localMCPArgument(index, server: server, settings: settings)
                }
                compactButton("Add argument") { settings.edit(id) { $0.arguments.append("") } }
                    .disabled(server.arguments.count >= 32)
                    .accessibilityIdentifier("AdaEditor.Settings.LocalMCP.AddArgument")
            }
            .disabled(connecting || connection != nil)

            localMCPNote("The MCP server runs with your account's permissions. Connect only commands you trust.")
            HStack(alignment: .center, spacing: 8) {
                if connecting || connection != nil {
                    compactButton(connecting ? "Cancel" : "Disconnect") { Task { await settings.disconnect(id) } }
                        .accessibilityIdentifier("AdaEditor.Settings.LocalMCP.Disconnect")
                } else {
                    compactButton("Connect") { Task { await settings.connect(id) } }
                        .disabled(server.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || server.executable.isEmpty)
                        .accessibilityIdentifier("AdaEditor.Settings.LocalMCP.Connect")
                    compactButton("Remove MCP server") { settings.remove(id) }
                }
            }
            localMCPNote(connecting ? "Connecting to local MCP…" : connection == nil ? "Local MCP disconnected" : "Local MCP connected")
            if let error = settings.errors[id] { localMCPNote(error) }
            if let connection {
                Text(L10n.text("MCP tools")).font(.system(size: 13)).foregroundColor(theme.editorColors.text)
                if connection.tools.isEmpty { localMCPNote("This MCP server has no tools.") }
                ForEach(connection.tools) { tool in localMCPTool(tool, server: id, settings: settings) }
            }
        }
    }

    private func localMCPArgument(_ index: Int, server: EditorLocalMCPSettings.Configuration, settings: EditorLocalMCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            localMCPField("MCP argument", id: "Argument.\(index)", text: Binding(get: {
                let arguments = settings.servers.first { $0.id == server.id }?.arguments ?? []
                return arguments.indices.contains(index) ? arguments[index] : ""
            }, set: { value in
                settings.edit(server.id) { if $0.arguments.indices.contains(index) { $0.arguments[index] = value } }
            }))
            HStack(spacing: 6) {
                compactButton("Move up") { moveLocalMCPArgument(index, next: index - 1, server: server.id, settings: settings) }
                    .disabled(index == 0)
                compactButton("Move down") { moveLocalMCPArgument(index, next: index + 1, server: server.id, settings: settings) }
                    .disabled(index + 1 == server.arguments.count)
                compactButton("Remove") { settings.edit(server.id) { if $0.arguments.indices.contains(index) { $0.arguments.remove(at: index) } } }
            }
        }
    }

    private func moveLocalMCPArgument(_ index: Int, next: Int, server: UUID, settings: EditorLocalMCPSettings) {
        settings.edit(server) { if $0.arguments.indices.contains(index), $0.arguments.indices.contains(next) { $0.arguments.swapAt(index, next) } }
    }

    private func localMCPTool(_ tool: EditorLocalMCPTool, server: UUID, settings: EditorLocalMCPSettings) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 8) {
                Toggle(tool.id, isOn: Binding(
                    get: { settings.isSelected(tool, server: server) }, set: { settings.select(tool, server: server, enabled: $0) }
                ))
                .toggleStyle(EditorMCPCheckboxStyle(colors: theme.editorColors))
                .disabled(tool.fingerprint == nil)
                .accessibilityIdentifier("AdaEditor.Settings.LocalMCP.Tool.\(tool.id)")
                Spacer()
                if tool.schema != nil {
                    compactButton(viewModel.localMCPToolDetails == tool.alias ? "Hide MCP input details" : "MCP input details") {
                        viewModel.localMCPToolDetails = viewModel.localMCPToolDetails == tool.alias ? nil : tool.alias
                    }
                }
            }
            if !tool.description.isEmpty {
                Text(tool.description).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            }
            if tool.schema == nil { localMCPNote("Studio cannot validate this MCP tool's input schema.") }
            if viewModel.localMCPToolDetails == tool.alias, let schema = tool.schema {
                ScrollView(.vertical) {
                    Text(localMCPSchemaText(schema)).font(.system(size: 11)).foregroundColor(theme.editorColors.text).padding(8)
                }
                .frame(height: 120)
                .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
            }
        }
    }

    private func localMCPSchemaText(_ schema: EditorLocalMCPToolSchema) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(schema.value)).map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    private func localMCPBinding(_ key: WritableKeyPath<EditorLocalMCPSettings.Configuration, String>, server: EditorLocalMCPSettings.Configuration,
                                 settings: EditorLocalMCPSettings) -> Binding<String> {
        Binding(get: { settings.servers.first { $0.id == server.id }?[keyPath: key] ?? "" }, set: { value in
            settings.edit(server.id) { $0[keyPath: key] = value }
        })
    }

    private func localMCPField(_ label: String, id: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.tr(label)).font(.system(size: 12)).foregroundColor(theme.editorColors.text)
            settingsInput("", text: text).accessibilityIdentifier("AdaEditor.Settings.LocalMCP.\(id)")
        }
    }

    private func localMCPNote(_ text: String) -> some View {
        Text(L10n.tr(text)).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
    }
}

private struct EditorMCPCheckboxStyle: ToggleStyle {
    let colors: EditorThemeColors

    func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isOn.wrappedValue.toggle() } label: {
            HStack(spacing: 7) {
                ZStack {
                    RoundedRectangleShape(cornerRadius: 3)
                        .stroke(configuration.isOn.wrappedValue ? colors.blue : colors.muted, lineWidth: 1)
                        .frame(width: 15, height: 15)
                    if configuration.isOn.wrappedValue {
                        Text("\u{E5CA}").font(AdaEditorMaterialSymbolFont.font(size: 12)).foregroundColor(colors.text)
                    }
                }
                .frame(width: 20, height: 20)
                configuration.label.font(.system(size: 12)).foregroundColor(colors.text).lineLimit(2)
            }
            .padding(.horizontal, 6)
            .frame(minHeight: 28)
            .background(RoundedRectangleShape(cornerRadius: 5).fill(colors.surface))
        }
        .buttonStyle(DefaultButtonStyle())
    }
}
#endif
