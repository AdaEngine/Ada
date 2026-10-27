@_spi(AdaEngine) import AdaEngine

extension EditorShaderGraphEditor {
    var canvasPoint: Vector2 { (Vector2(canvasViewportSize.width / 2, canvasViewportSize.height / 2) - canvas.pan) / canvas.zoom - Vector2(104, 50) }

    var nodeSearch: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                EditorShaderGraphSymbol(glyph: "\u{E145}").foregroundColor(theme.editorColors.blue)
                Text(L10n.tr("Add Node")).environment(\.font, .system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
                EditorShaderGraphAction(title: "Close", glyph: "\u{E5CD}") { search.isPresented = false }
            }.frame(height: 30)
            HStack(spacing: 8) {
                EditorShaderGraphSymbol(glyph: "\u{E8B6}").foregroundColor(theme.editorColors.muted)
                TextField(L10n.text("Search Nodes"), text: Binding(get: { search.query }, set: { search.query = $0 }))
                    .textFieldStyle(PlainTextFieldStyle()).accessibilityIdentifier("AdaEditor.ShaderGraph.Search")
            }.padding(.horizontal, 8).frame(height: 34)
                .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.background))
                .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(theme.editorColors.blue.opacity(0.65), lineWidth: 1) }
            if let graph = model.graph {
                let entries = search.entries(in: graph)
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if entries.isEmpty { Text(L10n.tr("No matching nodes")).foregroundColor(theme.editorColors.muted).padding(12) }
                        ForEach(entries) { entry in
                            Button {
                                model.insert(entry, using: search)
                                search.isPresented = false
                            } label: {
                                HStack(spacing: 8) {
                                    EditorShaderGraphSymbol(glyph: "\u{E8F0}").foregroundColor(theme.editorColors.muted)
                                    Text(verbatim: L10n.tr(EditorShaderGraphModel.operationTitle(entry.operation.rawValue))).lineLimit(1)
                                    Spacer(minLength: 0)
                                    EditorShaderGraphTypeBadge(type: entry.type.rawValue)
                                    EditorShaderGraphSymbol(glyph: "\u{E145}", size: 14).foregroundColor(theme.editorColors.blue)
                                }.padding(.horizontal, 8).frame(height: 32).frame(maxWidth: .infinity, alignment: .leading)
                                    .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
                                    .overlay { RoundedRectangleShape(cornerRadius: 5).stroke(theme.editorColors.border.opacity(0.6), lineWidth: 1) }
                            }.accessibilityIdentifier("AdaEditor.ShaderGraph.Search.\(entry.id)")
                        }
                    }
                }.frame(height: 216)
            }
        }.padding(12).frame(width: 360, height: 344, alignment: .topLeading)
            .font(.system(size: 12)).foregroundColor(theme.editorColors.text).buttonStyle(DefaultButtonStyle())
            .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
            .overlay { RoundedRectangleShape(cornerRadius: 8).stroke(theme.editorColors.border, lineWidth: 1) }
            .accessibilityIdentifier("AdaEditor.ShaderGraph.NodeSearch")
    }

    var parameterPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    EditorShaderGraphSymbol(glyph: "\u{E869}").foregroundColor(theme.editorColors.muted)
                    Text(L10n.text("Parameters")).environment(\.font, .system(size: 12, weight: .semibold))
                }
                ForEach((model.graph?.nodes ?? []).filter { $0.kind == "parameter" }, id: \.id) { node in
                    Button {
                        model.reveal(node.id, canvas: canvas, size: canvasViewportSize)
                    } label: {
                        HStack(spacing: 7) {
                            CircleShape().fill(EditorNodeCanvas.portColor(node.type.rawValue)).frame(width: 8, height: 8)
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: node.label ?? node.reference ?? node.id).lineLimit(2)
                                EditorShaderGraphTypeBadge(type: node.type.rawValue)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            EditorShaderGraphSymbol(glyph: "\u{E5CC}", size: 13).foregroundColor(theme.editorColors.muted)
                        }.padding(8).frame(maxWidth: .infinity, minHeight: 54, alignment: .leading)
                            .background(RoundedRectangleShape(cornerRadius: 6).fill(
                                model.selection.contains(node.id) ? theme.editorColors.blue.opacity(0.16) : theme.editorColors.surfaceElevated
                            ))
                            .overlay { RoundedRectangleShape(cornerRadius: 6).stroke(model.selection.contains(node.id) ? theme.editorColors.blue : theme.editorColors.border, lineWidth: 1) }
                    }.accessibilityIdentifier("AdaEditor.ShaderGraph.Parameter.\(node.id)")
                }
                EditorShaderGraphAction(title: "Add Parameter", glyph: "\u{E145}") {
                    search.open(at: canvasPoint)
                    search.query = L10n.tr("Parameter")
                }
            }.padding(10)
        }.font(.system(size: 12)).foregroundColor(theme.editorColors.text).buttonStyle(DefaultButtonStyle()).background(theme.editorColors.surface)
    }

    @ViewBuilder var graphContextMenu: some View {
        Button(L10n.text("Search Nodes")) { search.open(at: canvasPoint) }
        Button(L10n.text("Copy")) { copyNodes() }
        Button(L10n.text("Paste")) { pasteNodes() }
        Button(L10n.text("Group Selection")) { model.groupSelection() }
        Button(L10n.text("Add Comment")) { model.addComment(at: canvasPoint) }
        Button(L10n.text("Delete")) { model.removeSelection() }
    }

    var organizationPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                EditorShaderGraphAction(title: "Copy", glyph: "\u{E14D}") { copyNodes() }
                EditorShaderGraphAction(title: "Paste", glyph: "\u{E14F}") { pasteNodes() }
            }
            EditorShaderGraphAction(title: "Copy Graph Source", glyph: "\u{E86F}") { if let graph = model.graph { UIClipboard.setString(EditorShaderGraphTemplates.encode(graph)) } }
            EditorShaderGraphAction(title: "Group Selection", glyph: "\u{E8F1}") { model.groupSelection() }
            EditorShaderGraphAction(title: "Add Comment", glyph: "\u{E0CA}") { model.addComment(at: canvasPoint) }
            if let graph = model.graph {
                ForEach(graph.groups.keys.sorted(), id: \.self) { id in
                    if let group = graph.groups[id] {
                        field("Group", value: group.title) { value in model.edit(semantic: false) { $0.groups[id]?.title = value } }
                        HStack {
                            EditorShaderGraphAction(title: "Select", glyph: "\u{E5CA}") { model.selection = Set(group.nodes) }
                            EditorShaderGraphAction(title: "Remove Group", glyph: "\u{E872}", destructive: true) { model.edit(semantic: false) { $0.groups[id] = nil } }
                        }
                    }
                }
                ForEach(graph.notes.keys.sorted(), id: \.self) { id in
                    if let note = graph.notes[id] {
                        field("Comment", value: note.text) { value in model.edit(semantic: false) { $0.notes[id]?.text = value } }
                        HStack {
                            field("X", value: String(note.position.x)) { text in
                                if let value = Float(text), value.isFinite { model.edit(semantic: false) { $0.notes[id]?.position.x = value } }
                            }
                            field("Y", value: String(note.position.y)) { text in
                                if let value = Float(text), value.isFinite { model.edit(semantic: false) { $0.notes[id]?.position.y = value } }
                            }
                        }
                        EditorShaderGraphAction(title: "Remove Comment", glyph: "\u{E872}", destructive: true) { model.edit(semantic: false) { $0.notes[id] = nil } }
                    }
                }
            }
        }.disabled(model.isReadOnly)
    }

    func handleCanvasKey(_ event: KeyEvent) {
        guard event.status == .down else {
            return
        }
        if event.modifiers.contains(.command) {
            switch event.keyCode {
            case .a: model.selection = Set(model.graph?.nodes.map(\.id) ?? [])
            case .c: copyNodes()
            case .v: pasteNodes()
            default: break
            }
        } else {
            switch event.keyCode {
            case .space: search.open(at: canvasPoint)
            case .delete, .backspace: model.removeSelection()
            case .escape:
                search.isPresented = false
                interaction?.abort()
            default: break
            }
        }
    }

    private func copyNodes() { if let text = model.copySelection() { UIClipboard.setString(text) } }
    private func pasteNodes() { if let text = UIClipboard.getString() { model.paste(text, at: canvasPoint) } }
}
