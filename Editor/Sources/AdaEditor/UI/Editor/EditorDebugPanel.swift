import AdaDebugging
import AdaEngine
import Foundation

struct EditorDebugPanel: View {
    let debugger: EditorDebugger
    @Environment(\.theme) private var theme
    @State private var selectedTab = "Console"

    @State private var tooltip: String?
    @State private var tooltipTask: Task<Void, Never>?

    var body: some View {
        GeometryReader { geometry in
            let commandHeight: Float = selectedTab == "Console" ? 40 : 0
            VStack(spacing: 0) {
                header.frame(height: 36)
                tabs.frame(height: 32)
                divider
                HStack(spacing: 0) {
                    controls.frame(width: 40)
                    RectangleShape().fill(theme.editorColors.border).frame(width: 1)
                    content
                        .padding(12)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(height: max(0, geometry.size.height - 69 - commandHeight))
                if selectedTab == "Console" {
                    commandBar.frame(height: commandHeight)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .background(theme.editorColors.surfaceElevated)
        .mask(RoundedRectangleShape(cornerRadius: 12))
        .overlay(anchor: .topLeading) {
            if let tooltip {
                Text(tooltip)
                    .font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
                    .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.border, lineWidth: 1) }
                    .fixedSize()
                    .offset(x: 48, y: 76)
                    .allowsHitTesting(false)
                    .accessibilityIdentifier("AdaEditor.Debug.Tooltip")
            }
        }
        .onDisappear { updateTooltip(nil) }
        .accessibilityIdentifier("AdaEditor.Debug.Panel")
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Debug")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(theme.editorColors.text)
            Text(debugger.status.isEmpty ? debugger.session.reason : debugger.status)
                .font(.system(size: 11))
                .foregroundColor(theme.editorColors.muted)
                .lineLimit(1)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(EditorDebugLanguage.allCases, id: \.self) { language in
                    Button {
                        debugger.selectedLanguage = language
                    } label: {
                        Text(language.rawValue)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8)
                            .frame(height: 24)
                    }
                    .buttonStyle(EditorDebugButtonStyle(theme: theme, active: debugger.selectedLanguage == language))
                    .accessibilityIdentifier("AdaEditor.Debug.Language.\(language.rawValue)")
                }
            }
        }
        .padding(.horizontal, 12)
        .background(theme.editorColors.surface)
    }

    private var tabs: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 4) {
                ForEach(["Breakpoints", "Call Stack", "Variables", "Watches", "Console"], id: \.self) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab)
                            .font(.system(size: 11))
                            .padding(.horizontal, 10)
                            .frame(height: 26)
                    }
                    .buttonStyle(EditorDebugButtonStyle(theme: theme, active: selectedTab == tab))
                    .accessibilityIdentifier("AdaEditor.Debug.Tab.\(tab)")
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
        }
        .background(theme.editorColors.surface)
    }

    private var controls: some View {
        ScrollView(.vertical) {
            VStack(spacing: 4) {
                action("Pause", glyph: "\u{E034}", command: "pause", enabled: debugger.session.state == .running)
                action("Continue", glyph: "\u{E037}", command: "continue", enabled: debugger.session.state == .paused)
                divider.padding(.horizontal, 6)
                action("Step Over", glyph: "\u{E5DA}", command: "next", enabled: debugger.session.state == .paused)
                action("Step Into", glyph: "\u{E258}", command: "stepIn", enabled: debugger.session.state == .paused)
                action("Step Out", glyph: "\u{E25A}", command: "stepOut", enabled: debugger.session.state == .paused)
                divider.padding(.horizontal, 6)
                iconButton("Stop", glyph: "\u{E047}", identifier: "stop", enabled: debugger.isActive) { debugger.stop() }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
        .background(theme.editorColors.surface.opacity(0.5))
        .accessibilityIdentifier("AdaEditor.Debug.Controls")
    }

    private var divider: some View {
        RectangleShape().fill(theme.editorColors.border).frame(height: 1)
    }

    private var commandBar: some View {
        VStack(spacing: 0) {
            divider.accessibilityIdentifier("AdaEditor.Debug.CommandDivider")
            HStack(spacing: 10) {
                Text(">")
                    .foregroundColor(theme.editorColors.muted)
                TextField(
                    debugger.selectedLanguage == .swift ? "LLDB command" : "AdaScript command",
                    text: Binding(get: { debugger.command }, set: { debugger.command = $0 }),
                    onSubmit: debugger.sendCommand
                )
                .textFieldStyle(PlainTextFieldStyle())
                .foregroundColor(theme.editorColors.text)
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 30, maxHeight: 30)
                .accessibilityIdentifier("AdaEditor.Debug.Command")
                Text("Enter")
                    .font(.system(size: 10))
                    .foregroundColor(theme.editorColors.muted)
            }
            .font(AdaEditorCodeFont.font(size: 12))
            .padding(.horizontal, 12)
            .frame(height: 39)
        }
        .background(theme.editorColors.surfaceElevated)
    }

    @ViewBuilder private var content: some View {
        switch selectedTab {
        case "Breakpoints":
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 6) {
                    if debugger.breakpoints.isEmpty {
                        Text("Click the source gutter to add a breakpoint.")
                    }
                    ForEach(debugger.breakpoints) { breakpoint in
                        let target = URL(fileURLWithPath: breakpoint.path).pathExtension == "swift" ? debugger.swift : debugger.adaScript
                        HStack(spacing: 8) {
                            Button(breakpoint.enabled ? "●" : "○") {
                                debugger.setBreakpointEnabled(breakpoint, enabled: !breakpoint.enabled)
                            }
                            Text("\(URL(fileURLWithPath: breakpoint.path).lastPathComponent):\(breakpoint.line)")
                            Text(target.verifiedBreakpoints[breakpoint.id] == true ? "Verified" : "Pending")
                                .foregroundColor(theme.editorColors.muted)
                            Button("Remove") { debugger.toggleBreakpoint(path: breakpoint.path, line: breakpoint.line) }
                        }
                        if let message = target.breakpointMessages[breakpoint.id] {
                            Text(message)
                        }
                    }
                }
                .font(.system(size: 11))
            }
        case "Call Stack":
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(debugger.session.threads.map(\.id), id: \.self) { identifier in
                        Button(debugger.session.threads.first { $0.id == identifier }?.name ?? "Thread") {
                            Task { await debugger.session.selectThread(identifier) }
                        }
                    }
                    ForEach(debugger.session.frames) { frame in
                        Button("\(frame.name) · \(frame.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? ""):\(frame.line)") {
                            Task { await debugger.session.selectFrame(frame) }
                        }
                        .foregroundColor(debugger.session.selectedFrameID == frame.id ? theme.editorColors.blue : theme.editorColors.text)
                    }
                }
                .font(.system(size: 11))
            }
        case "Variables":
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(debugger.session.variables.enumerated()), id: \.offset) { item in
                        EditorDebugVariableRow(session: debugger.session, variable: item.element, depth: 0)
                            .id("\(debugger.session.stopGeneration):\(debugger.session.selectedFrameID ?? -1):\(item.offset)")
                    }
                }
            }
        case "Watches":
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("Expression", text: Binding(get: { debugger.watchExpression }, set: { debugger.watchExpression = $0 }), onSubmit: debugger.addWatch)
                        .textFieldStyle(PlainTextFieldStyle())
                        .foregroundColor(theme.editorColors.text)
                        .accessibilityIdentifier("AdaEditor.Debug.WatchExpression")
                    Button("Add") { debugger.addWatch() }
                        .accessibilityIdentifier("AdaEditor.Debug.AddWatch")
                }
                ScrollView([.horizontal, .vertical]) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(debugger.watches, id: \.self) { expression in
                            HStack(spacing: 8) {
                                Text("\(expression) = \(debugger.session.watchValues[expression] ?? "Pause to evaluate")")
                                Button("Remove") { debugger.removeWatch(expression) }
                            }
                        }
                    }
                    .font(.system(size: 11))
                }
            }
        default:
            ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(debugger.session.console.enumerated()), id: \.offset) { line in
                        Text(line.element).font(AdaEditorCodeFont.font(size: 11))
                            .foregroundColor(theme.editorColors.text)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    private func action(_ title: String, glyph: String, command: String, enabled: Bool) -> some View {
        iconButton(title, glyph: glyph, identifier: command, enabled: enabled) {
            Task { await debugger.session.control(command) }
        }
    }

    private func iconButton(_ title: String, glyph: String, identifier: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph)
                .font(AdaEditorMaterialSymbolFont.font(size: 19))
                .frame(width: 30, height: 30)
        }
        .buttonStyle(EditorDebugButtonStyle(theme: theme, active: false))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
        .onHover { updateTooltip($0 ? title : nil) }
        .accessibilityIdentifier("AdaEditor.Debug.\(identifier)")
    }

    private func updateTooltip(_ title: String?) {
        tooltipTask?.cancel()
        tooltip = nil
        guard let title else {
            return
        }
        tooltipTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else {
                return
            }
            tooltip = title
        }
    }
}

private struct EditorDebugVariableRow: View {
    let session: DebugSession
    let variable: DebugVariable
    let depth: Int
    @State private var children: [DebugVariable] = []
    @State private var expanded = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if variable.reference > 0, depth < 8 {
                    Button(expanded ? "▾" : "▸") {
                        expanded.toggle()
                        if expanded {
                            Task {
                                do { children = try await session.children(reference: variable.reference) } catch { self.error = error.localizedDescription }
                            }
                        }
                    }
                }
                Text("\(variable.name): \(variable.type ?? "") = \(variable.value)")
                if let address = variable.memoryReference {
                    Text(address)
                }
            }
            if expanded {
                if let error {
                    Text(error)
                }
                ForEach(Array(children.enumerated()), id: \.offset) { child in
                    AnyView(Self(session: session, variable: child.element, depth: depth + 1))
                        .padding(.leading, 14)
                }
            }
        }
        .font(AdaEditorCodeFont.font(size: 11))
    }
}

private struct EditorDebugButtonStyle: ButtonStyle {
    let theme: Theme
    let active: Bool

    func makeBody(configuration: Configuration) -> some View {
        let highlighted = configuration.state.isHighlighted || configuration.state.isSelected
        return configuration.label
            .foregroundColor(active ? theme.editorColors.blue : (highlighted ? theme.editorColors.text : theme.editorColors.muted))
            .background(
                RoundedRectangleShape(cornerRadius: 5)
                    .fill(
                        active ? theme.editorColors.blue.opacity(0.16) : (highlighted ? theme.editorColors.surfaceElevated : Color.clear)
                    )
            )
    }
}
