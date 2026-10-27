@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorShaderGraphEditor: View {
    enum Presentation { case canvas, inspector }

    let model: EditorShaderGraphModel
    var presentation: Presentation = .canvas
    var modelDocuments: [EditorAssetDocument] = []
    var workbench: EditorWorkbenchViewModel?
    @Environment(\.theme) var theme
    var canvas: EditorNodeCanvasState { model.canvas }
    var canvasViewportSize: Size { model.canvasViewportSize }
    @State var interaction: EditorNodeCanvasInteraction?
    @State var search = EditorShaderGraphSearch()
    @State private var didFit = false
    @State private var showsSource = false
    @State private var operation = "constant"
    @State private var valueType = "float"
    @State private var preview = EditorShaderGraphPreview()

    var body: some View {
        Group {
            switch presentation {
            case .canvas: workspace
            case .inspector:
                VStack(alignment: .leading, spacing: 0) {
                    adaEditorInspectorTitle(theme: theme)
                    inspector
                }.accessibilityIdentifier("AdaEditor.ShaderGraph.Inspector")
            }
        }.onAppear {
            if presentation == .inspector { preview.schedule(model.graph, basePath: model.url?.path) }
        }.onChange(of: model.semanticRevision) { _, _ in
            if presentation == .inspector { preview.schedule(model.graph, basePath: model.url?.path) }
        }.onDisappear { preview.cancel() }
    }

    private var workspace: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                toolbar()
                HStack(spacing: 0) {
                    if geometry.size.width >= 1_000 { parameterPanel.frame(width: 180) }
                    if showsSource {
                        EditorShaderGraphSourceView(model: model, workbench: workbench)
                    } else {
                        EditorNodeCanvas(
                            items: model.canvasItems,
                            wires: model.canvasWires,
                            selection: model.selection,
                            state: canvas,
                            revision: model.layoutRevision &+ model.semanticRevision,
                            interaction: interaction,
                            decorations: model.canvasDecorations,
                            onKeyEvent: handleCanvasKey,
                            viewportSizeChanged: { size in
                                model.canvasViewportSize = size
                                if !didFit, size.width > 0, size.height > 0 {
                                    canvas.fit(model.canvasItems, in: size)
                                    didFit = true
                                }
                            },
                            selectedWire: model.selectedWire
                        ).contextMenu { graphContextMenu }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if let message = model.diagnosticMessage {
                    Button {
                        if let id = model.validation?.nodeID { model.reveal(id, canvas: canvas, size: canvasViewportSize) }
                    } label: {
                        Text(verbatim: message).font(.system(size: 11)).foregroundColor(.red).lineLimit(3)
                    }.buttonStyle(DefaultButtonStyle()).padding(8)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height)
        }.overlay(anchor: .topLeading) {
            if search.isPresented {
                nodeSearch.padding(8).offset(y: 44)
            }
        }.background(theme.editorColors.background).accessibilityIdentifier("AdaEditor.ShaderGraph.Editor").onAppear {
            let pointer = model.canvasInteraction()
            pointer.emptyDrop = { [weak pointer] endpoint, point in
                search.open(at: point, endpoint: endpoint)
                search.replacedInput = pointer?.replacedInput
            }
            interaction = pointer
        }.onDisappear {
            interaction?.abort()
        }
    }

    private func toolbar() -> some View {
        ScrollView(.horizontal) {
        HStack(spacing: 6) {
            EditorShaderGraphAction(title: "Undo", glyph: "\u{E166}") { model.undo() }.disabled(!model.canUndo)
            EditorShaderGraphAction(title: "Redo", glyph: "\u{E15A}") { model.redo() }.disabled(!model.canRedo)
            EditorShaderGraphAction(title: "Save", glyph: "\u{E161}") { model.save() }.disabled(!model.isDirty || model.isReadOnly).accessibilityIdentifier("AdaEditor.ShaderGraph.Save")
            EditorShaderGraphAction(title: "Reload", glyph: "\u{E5D5}") { model.reload() }
            EditorShaderGraphAction(title: "Search Nodes", glyph: "\u{E8B6}", selected: search.isPresented) { search.open(at: canvasPoint) }
                .accessibilityIdentifier("AdaEditor.ShaderGraph.OpenSearch")
            Spacer(minLength: 4)
            Button("−") { canvas.zoom(by: 0.8, around: [canvasViewportSize.width / 2, canvasViewportSize.height / 2]) }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
            Button("+") { canvas.zoom(by: 1.25, around: [canvasViewportSize.width / 2, canvasViewportSize.height / 2]) }
                .buttonStyle(EditorUIDesignerButtonStyle(colors: theme.editorColors, bordered: true))
            EditorShaderGraphAction(title: "Fit", glyph: "\u{E5D0}") { canvas.fit(model.canvasItems, in: canvasViewportSize) }
            EditorShaderGraphAction(title: "Pan", glyph: "\u{E925}", selected: canvas.panMode) { canvas.panMode.toggle() }
            EditorShaderGraphAction(title: "Source", glyph: "\u{E86F}", selected: showsSource) { showsSource.toggle() }
                .accessibilityIdentifier("AdaEditor.ShaderGraph.Source")
        }.foregroundColor(theme.editorColors.text).padding(.horizontal, 8).frame(height: 44)
        }.frame(height: 44).background(theme.editorColors.surface)
    }

    private var inspector: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                EditorShaderGraphSection(title: "Preview", glyph: "\u{E8F4}") { previewPanel }
                EditorShaderGraphSection(title: "Add Node", glyph: "\u{E145}") {
                    Text(L10n.tr("Node Type")).foregroundColor(theme.editorColors.muted)
                    EditorEnumField(
                        cases: availableOperations.map { L10n.tr(EditorShaderGraphModel.operationTitle($0.rawValue)) },
                        selection: Binding(
                            get: { L10n.tr(EditorShaderGraphModel.operationTitle(operation)) },
                            set: { title in operation = availableOperations.first { L10n.tr(EditorShaderGraphModel.operationTitle($0.rawValue)) == title }?.rawValue ?? "constant" }
                        ),
                        accessibilityID: "AdaEditor.ShaderGraph.Operation"
                    )
                    Text(L10n.tr("Value Type")).foregroundColor(theme.editorColors.muted)
                    EditorEnumField(cases: availableTypes, selection: $valueType, accessibilityID: "AdaEditor.ShaderGraph.Type")
                    EditorShaderGraphAction(title: "Add Node", glyph: "\u{E145}", selected: true) { addNode() }
                        .disabled(model.isReadOnly).accessibilityIdentifier("AdaEditor.ShaderGraph.AddNode")
                }
                EditorShaderGraphSection(title: "Selected Node", glyph: "\u{E8F0}") {
                    if let node = model.selectedNode { nodeInspector(node) }
                    else { Text(L10n.text("Select a node to edit its properties.")).foregroundColor(theme.editorColors.muted) }
                }
                if let graph = model.graph { EditorShaderGraphSection(title: "Output", glyph: "\u{E5DA}") { outputInspector(graph) } }
                EditorShaderGraphSection(title: "Graph Tools", glyph: "\u{E869}") { organizationPanel }
            }.padding(12)
        }.font(.system(size: 12)).foregroundColor(theme.editorColors.text).buttonStyle(DefaultButtonStyle()).background(theme.editorColors.surface)
    }

    private var availableOperations: [ShaderGraph.Operation] { ShaderGraph.Operation.allCases.filter { $0 != .output && ($0 != .spriteTexture || model.graph?.target == .sprite) } }

    private var availableTypes: [String] {
        switch ShaderGraph.Operation(rawValue: operation) {
        case .parameter: ["float", "bool", "vector2", "vector3", "vector4", "color", "texture2D"]
        case .constant: ["float", "bool", "vector2", "vector3", "vector4", "color"]
        case .uv: ["vector2"]
        case .spriteTexture: ["color"]
        case .texture: ["texture2D"]
        case .sampleTexture: ["vector4"]
        case .time, .noise2D: ["float"]
        case .combine2: ["vector2"]
        case .combine3: ["vector3"]
        case .combine4: ["vector4"]
        default: ["float", "vector2", "vector3", "vector4", "color"]
        }
    }

    private var previewPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            if preview.material != nil {
                if preview.selectedModel?.isLoading != true {
                    EditorShaderGraphViewport(model: preview).id("\(preview.material?.program.target.rawValue ?? "")-\(preview.shape)-\(preview.selectedModel?.asset != nil)").frame(
                        height: 190
                    )
                }
                if model.graph?.target == .pbrSurface {
                    EditorEnumField(
                        cases: [L10n.tr("Sphere"), L10n.tr("Plane")] + modelDocuments.map(\.relativePath),
                        selection: Binding(
                            get: { preview.shape == "sphere" ? L10n.tr("Sphere") : preview.shape == "plane" ? L10n.tr("Plane") : preview.shape },
                            set: { value in
                                preview.selectedModel?.cancel()
                                preview.selectedModel = nil
                                if value == L10n.tr("Sphere") {
                                    preview.shape = "sphere"
                                } else if value == L10n.tr("Plane") {
                                    preview.shape = "plane"
                                } else if let document = modelDocuments.first(where: { $0.relativePath == value }) {
                                    preview.shape = value
                                    let selected = EditorModelAssetPreviewModel()
                                    preview.selectedModel = selected
                                    selected.load(document)
                                }
                            }
                        ),
                        accessibilityID: "AdaEditor.ShaderGraph.PreviewShape"
                    )
                }
                HStack {
                    EditorShaderGraphAction(title: preview.isPlaying ? "Pause" : "Play", glyph: preview.isPlaying ? "\u{E034}" : "\u{E037}") { preview.isPlaying.toggle() }
                    EditorShaderGraphAction(title: "Restart", glyph: "\u{E5D5}") { preview.restart() }
                }
            }
            if preview.isCompiling { Text(L10n.text("Compiling graph…")).foregroundColor(theme.editorColors.muted) }
            if let error = preview.error ?? preview.selectedModel?.error {
                Button {
                    if let id = preview.errorNode { model.selection = [id] }
                } label: {
                    Text(verbatim: error).foregroundColor(.red).lineLimit(4)
                }
            }
        }
    }

    private func addNode() {
        guard let op = ShaderGraph.Operation(rawValue: operation) else {
            return
        }
        let type: ShaderGraph.ValueType
        switch op {
        case .uv: type = .vector2
        case .spriteTexture: type = .color
        case .texture: type = .texture2D
        case .sampleTexture: type = .vector4
        case .time, .noise2D: type = .float
        case .combine2: type = .vector2
        case .combine3: type = .vector3
        case .combine4: type = .vector4
        default: type = ShaderGraph.ValueType(rawValue: availableTypes.contains(valueType) ? valueType : availableTypes[0]) ?? .float
        }
        model.addNode(op, type: type, at: (Vector2(140, 100) - canvas.pan) / canvas.zoom)
    }

    private func nodeInspector(_ node: ShaderGraph.Node) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: node.label ?? node.reference ?? L10n.tr(EditorShaderGraphModel.operationTitle(node.kind))).lineLimit(2)
                Spacer(minLength: 0)
                EditorShaderGraphTypeBadge(type: node.type.rawValue)
            }
            if (model.graph?.outputPorts(for: node).count ?? 0) > 1 {
                EditorShaderGraphAction(title: model.expandedPorts.contains(node.id) ? "Hide Channels" : "Show Channels", glyph: "\u{E8F1}") {
                    if !model.expandedPorts.insert(node.id).inserted { model.expandedPorts.remove(node.id) }
                }
            }
            field("Name", value: node.label ?? "") { value in model.editNode(node.id) { $0.label = value.isEmpty ? nil : value } }
            if node.kind == "parameter" || node.kind == "texture" {
                field(node.kind == "parameter" ? "Parameter ID" : "Texture", value: node.reference ?? "") { value in model.editNode(node.id) { $0.reference = value } }
            }
            if node.kind == "parameter", node.type == .texture2D {
                field("Default Texture", value: node.defaultTexture ?? "") { value in model.editNode(node.id) { $0.defaultTexture = value.isEmpty ? nil : value } }
            }
            EditorShaderGraphValueEditor(model: model, node: node).id(node.id)
            ForEach(node.inputs.keys.sorted(), id: \.self) { port in
                HStack {
                    Text(verbatim: L10n.tr(EditorShaderGraphModel.portTitle(port)))
                    Spacer()
                    EditorShaderGraphAction(title: "Disconnect", glyph: "\u{E14C}") { model.editNode(node.id) { $0.inputs[port] = nil } }
                }
            }
            EditorShaderGraphAction(title: "Delete", glyph: "\u{E872}", destructive: true) { model.removeSelection() }.disabled(node.id == model.graph?.output || model.isReadOnly)
        }.disabled(model.isReadOnly)
    }

    private func outputInspector(_ graph: ShaderGraph) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: graph.target == .sprite ? "Sprite" : "PBR Surface")
            Text(L10n.tr("Render Mode")).foregroundColor(theme.editorColors.muted)
            EditorEnumField(
                cases: ShaderGraph.RenderSettings.Mode.allCases.map { L10n.tr($0.rawValue.capitalized) },
                selection: Binding(
                    get: { L10n.tr(graph.renderSettings.mode.rawValue.capitalized) },
                    set: { title in
                        if let mode = ShaderGraph.RenderSettings.Mode.allCases.first(where: { L10n.tr($0.rawValue.capitalized) == title }) { model.edit { $0.renderSettings.mode = mode } }
                    }
                ),
                accessibilityID: "AdaEditor.ShaderGraph.AlphaMode"
            )
            field("Alpha Cutoff", value: String(graph.renderSettings.alphaCutoff)) { text in
                if let value = Float(text), value.isFinite, (0...1).contains(value) { model.edit { $0.renderSettings.alphaCutoff = value } }
            }
            Toggle(L10n.text("Double Sided"), isOn: Binding(get: { graph.renderSettings.doubleSided }, set: { value in model.edit { $0.renderSettings.doubleSided = value } }))
        }.disabled(model.isReadOnly)
    }

    func field(_ title: String, value: String, set: @escaping (String) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(title))
            EditorUIDesignerField(placeholder: title, text: Binding(get: { value }, set: set))
        }.drawingGroup()
    }
}
