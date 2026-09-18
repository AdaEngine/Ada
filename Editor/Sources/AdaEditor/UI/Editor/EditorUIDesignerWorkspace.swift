@_spi(AdaEngine) import AdaEngine
import Math

extension EditorUISceneEditor {
    var designerBody: some View {
        GeometryReader { geometry in
            let layout = EditorUIDesignerLayout(size: geometry.size)
            AnyView(
                VStack(spacing: 0) {
                    AnyView(designerToolbar(layout: layout)).frame(height: layout.toolbarHeight)
                    panelDivider
                    if !layout.showsSidebars, !model.showsSource {
                        HStack(spacing: 4) {
                            ForEach(EditorUIDesignerPane.allCases, id: \.self) { pane in
                                Button(pane.rawValue) { compactPane = pane }
                                    .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: compactPane == pane))
                                    .accessibilityIdentifier("AdaEditor.UIScene.Pane.\(pane.rawValue)")
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).frame(height: 38)
                    }
                    if model.showsSource {
                        AnyView(sourceEditor).frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if layout.showsSidebars {
                        HStack(spacing: 0) {
                            AnyView(designerLibrary).frame(width: layout.sidebarWidth, height: layout.contentHeight)
                            RectangleShape().fill(theme.editorColors.border.opacity(0.5)).frame(width: 1)
                            AnyView(designerCanvas(layout: layout)).frame(width: layout.canvasWidth, height: layout.contentHeight)
                                .accessibilityIdentifier("AdaEditor.UIScene.CanvasPanel")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch compactPane {
                        case .library: AnyView(designerLibrary).frame(width: layout.size.width, height: layout.contentHeight)
                        case .canvas:
                            AnyView(designerCanvas(layout: layout)).frame(width: layout.canvasWidth, height: layout.contentHeight)
                                .accessibilityIdentifier("AdaEditor.UIScene.CanvasPanel")
                        }
                    }
                    AnyView(designerStatus)
                }
                .frame(width: geometry.size.width, height: geometry.size.height)
                .background(theme.editorColors.surface)
                .foregroundColor(theme.editorColors.text)
                .font(.system(size: 12))
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors))
            )
        }
        .accessibilityIdentifier("AdaEditor.UIScene")
    }

    func designerToolbar(layout: EditorUIDesignerLayout) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 10) {
                HStack(spacing: 7) {
                    symbol("\u{E8F1}").foregroundColor(theme.editorColors.blue)
                    Text("UI Designer").font(.system(size: 12, weight: .semibold))
                }
                if layout.size.width >= 1100 {
                    modeControls
                }
                Spacer()
                iconButton("\u{E166}", title: "Undo", action: model.undo).disabled(!model.canUndo || model.isReadOnly)
                    .opacity(model.canUndo && !model.isReadOnly ? 1 : 0.35)
                iconButton("\u{E15A}", title: "Redo", action: model.redo).disabled(!model.canRedo || model.isReadOnly)
                    .opacity(model.canRedo && !model.isReadOnly ? 1 : 0.35)
                Button(model.showsSource ? "Designer" : "YAML") { model.showsSource.toggle() }
                    .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: model.showsSource, bordered: true))
                    .accessibilityIdentifier("AdaEditor.UIScene.SourceToggle")
                if layout.size.width >= 1100 {
                    dimensions
                    zoomControls(layout: layout)
                }
            }
            .frame(height: 34)
            if layout.size.width < 1100 {
                HStack(spacing: 8) {
                    modeControls
                    Spacer()
                    if layout.size.width >= 560 {
                        dimensions
                    }
                    zoomControls(layout: layout)
                }
                .frame(height: 30)
            }
            if layout.size.width < 560 {
                HStack {
                    Text("Canvas size").foregroundColor(theme.editorColors.muted)
                    Spacer()
                    dimensions
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    var modeControls: some View {
        HStack(spacing: 2) {
            Button("Design") {
                model.isInteractive = false
                model.showsSource = false
            }
            .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: !model.isInteractive && !model.showsSource))
            .accessibilityIdentifier("AdaEditor.UIScene.Mode")
            Button("Interact") {
                model.isInteractive = true
                model.showsSource = false
            }
            .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: model.isInteractive && !model.showsSource))
            .accessibilityIdentifier("AdaEditor.UIScene.Interact")
        }
        .padding(2)
        .background(RoundedRectangleShape(cornerRadius: 8).fill(theme.editorColors.surfaceElevated))
    }

    var dimensions: some View {
        HStack(spacing: 6) {
            Text("W").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.editorColors.muted)
            EditorUIDesignerField(placeholder: "Width", text: floatBinding(\.width)).frame(width: 58)
                .accessibilityIdentifier("AdaEditor.UIScene.Width")
            Text("H").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.editorColors.muted)
            EditorUIDesignerField(placeholder: "Height", text: floatBinding(\.height)).frame(width: 58)
                .accessibilityIdentifier("AdaEditor.UIScene.Height")
        }
        .frame(height: 30)
    }

    func zoomControls(layout: EditorUIDesignerLayout) -> some View {
        let zoom = fitsCanvas ? layout.fitZoom(width: model.width, height: model.height) : model.zoom
        return HStack(spacing: 2) {
            Button("−") {
                model.zoom = max(0.02, zoom - 0.1)
                fitsCanvas = false
            }
            .frame(width: 26)
            Button("\(Int((zoom * 100).rounded()))%") {
                model.zoom = 1
                fitsCanvas = false
            }
            .frame(width: 46)
            Button("+") {
                model.zoom = min(3, zoom + 0.1)
                fitsCanvas = false
            }
            .frame(width: 26)
            Button("Fit") { fitsCanvas = true }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: fitsCanvas))
                .accessibilityIdentifier("AdaEditor.UIScene.Fit")
        }
    }

    func designerCanvas(layout: EditorUIDesignerLayout) -> some View {
        let zoom = fitsCanvas ? layout.fitZoom(width: model.width, height: model.height) : model.zoom
        return ScrollView([.horizontal, .vertical]) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    symbol("\u{E8F4}", size: 13).foregroundColor(theme.editorColors.muted)
                    Text(model.sourceURL?.lastPathComponent ?? "Untitled.ui").font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Text("\(Int(model.width)) × \(Int(model.height))").font(AdaEditorCodeFont.font(size: 10))
                        .foregroundColor(theme.editorColors.muted)
                }
                .frame(width: model.width * zoom, height: 22)
                ZStack {
                    if let preview = model.preview {
                        EditorUISceneSurface(preview: preview, model: model, zoom: zoom)
                            .frame(width: model.width * zoom, height: model.height * zoom)
                            .accessibilityIdentifier("AdaEditor.UIScene.Canvas")
                    }
                    if isEmptyCanvas, !model.isInteractive {
                        emptyCanvas
                            .frame(width: min(320, model.width * zoom - 24))
                    } else if model.preview == nil {
                        Text("Preview unavailable").foregroundColor(theme.editorColors.muted)
                    }
                }
                .frame(width: model.width * zoom, height: model.height * zoom)
                .background(theme.editorColors.surfaceElevated)
                .border(theme.editorColors.border.opacity(0.85))
                .accessibilityIdentifier("AdaEditor.UIScene.Artboard")
                Text(model.isInteractive ? "Interact with the live interface" : "Select a layer on the canvas to edit its properties")
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                    .frame(width: model.width * zoom)
            }
            .padding(32)
            .frame(minWidth: layout.canvasWidth, minHeight: layout.contentHeight)
        }
        .background {
            Canvas { context, size in
                context.drawRect(Rect(origin: .zero, size: size), color: theme.editorColors.background)
                for y in stride(from: Float(12), to: size.height, by: 24) {
                    for x in stride(from: Float(12), to: size.width, by: 24) {
                        context.drawEllipse(in: Rect(x: x, y: y, width: 1.5, height: 1.5), color: theme.editorColors.border.opacity(0.6))
                    }
                }
            }
        }
    }

    var isEmptyCanvas: Bool {
        ["ZStack", "VStack", "HStack", "Group"].contains(model.document.root.type)
            && model.document.root.children.isEmpty && model.document.root.modifiers.isEmpty
    }

    var emptyCanvas: some View {
        VStack(spacing: 12) {
            symbol("\u{E8F1}", size: 28)
                .foregroundColor(theme.editorColors.blue)
                .padding(14)
                .background(RoundedRectangleShape(cornerRadius: 14).fill(theme.editorColors.blue.opacity(0.10)))
            Text("Start with a component").font(.system(size: 16, weight: .semibold))
            Text("Add content from the library, then arrange it on the canvas.")
                .font(.system(size: 12)).foregroundColor(theme.editorColors.muted).multilineTextAlignment(.center)
            Button("Add Text") { model.add("Text") }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, selected: true, bordered: true))
                .disabled(model.isReadOnly)
                .accessibilityIdentifier("AdaEditor.UIScene.Empty.AddText")
        }
        .padding(16)
    }

    var sourceEditor: some View {
        TextEditor(
            text: Binding(get: { model.rawSource }, set: { model.editSource($0) }),
            tokenSpans: EditorSyntaxHighlighter.spans(for: model.rawSource, language: .yaml, palette: colorPalette)
        )
        .font(AdaEditorCodeFont.font(size: 12))
        .foregroundColor(colorPalette.plainText)
        .accentColor(theme.editorColors.blue)
        .textEditorColors(
            TextEditorColors(
                background: theme.editorColors.surfaceElevated,
                border: .clear,
                focusedBorder: theme.editorColors.blue,
                gutter: colorPalette.lineNumber,
                gutterRule: theme.editorColors.border.opacity(0.45),
                currentLineBackground: colorPalette.currentLineBackground,
                selection: colorPalette.selection
            )
        )
        .disabled(model.isReadOnly)
        .accessibilityIdentifier("AdaEditor.UIScene.Source")
    }

    var designerStatus: some View {
        HStack(spacing: 8) {
            symbol(model.error == nil ? "\u{E86C}" : "\u{E001}", size: 12)
                .foregroundColor(model.error == nil ? theme.editorColors.muted : .red)
            Text(model.error ?? model.lastAction.map { "Action: \($0)" } ?? (model.isReadOnly ? "Read only" : (model.isInteractive ? "Interactions enabled" : "Ready")))
                .font(.system(size: 10)).lineLimit(1)
            Spacer()
            Text("\(rows.count) \(rows.count == 1 ? "layer" : "layers")")
                .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
        }
        .padding(.horizontal, 12).frame(height: 28)
        .background(theme.editorColors.surfaceElevated)
    }
}
