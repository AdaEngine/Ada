@_spi(AdaEngine) import AdaEngine

struct EditorCSGInspectorSelection: Equatable {
    struct Box: Equatable, Identifiable {
        let id: String
        let name: String
        let operation: TriangleBooleanOperation
        let enabled: Bool
    }

    let groupID: String
    let boxes: [Box]
    let selectedBoxID: String?
    let texture: String
    let uvRepeats: String

    init?(model: EditorSceneModel, selected: EditorSceneEntity) {
        if selected.components[EditorCSGScene.groupType] != nil {
            groupID = selected.id
            selectedBoxID = nil
        } else if selected.components[EditorCSGScene.boxType] != nil, let parent = selected.parent,
            model.entities.contains(where: { $0.id == parent && $0.components[EditorCSGScene.groupType] != nil }) {
            groupID = parent
            selectedBoxID = selected.id
        } else {
            return nil
        }
        let resolvedGroupID = groupID
        let settings = model.entities.first { $0.id == resolvedGroupID }?.components[EditorCSGScene.groupType]
        texture = settings?["texture"]?.stringValue ?? ""
        uvRepeats = settings?["uvRepeats"]?.stringValue ?? "1"
        boxes = model.csgBoxes(in: groupID).map {
            let rawOperation = $0.components[EditorCSGScene.boxType]?["operation"]?.stringValue
            let operation = rawOperation.flatMap(TriangleBooleanOperation.init(rawValue:))
            return .init(id: $0.id, name: $0.name, operation: operation ?? .union, enabled: $0.enabled)
        }
    }
}

enum EditorCSGEdit {
    case select(String)
    case addShape(CSGShape, groupID: String)
    case moveBox(String, groupID: String, delta: Int)
    case operation(TriangleBooleanOperation, boxID: String)
    case texture(String, groupID: String)
    case uvRepeats(Int, groupID: String)
}

struct EditorCSGInspector: View {
    let selection: EditorCSGInspectorSelection
    let status: EditorCSGPreview.Status?
    let edit: (EditorCSGEdit) -> Void
    let isReadOnly: Bool
    let textureReferences: [String]

    @Environment(\.theme) private var theme
    @State private var shapeToAdd = CSGShape.box

    private let operationLabels = ["union": "Union", "subtract": "Difference", "intersect": "Intersection"]
    static let shapeLabels = ["box": "CSG Cube", "sphere": "CSG Sphere", "cylinder": "CSG Cylinder"]

    var body: some View {
        let base = selection.boxes.first(where: \.enabled)
        let index = selection.boxes.firstIndex { $0.id == selection.selectedBoxID }
        VStack(alignment: .leading, spacing: 6) {
            if let index {
                let box = selection.boxes[index]
                Text(L10n.text("CSG Operation")).font(.system(size: 11))
                if base?.id == box.id {
                    Text(L10n.text("CSG Base"))
                        .font(.system(size: 12))
                } else {
                    EditorEnumField(
                        cases: ["union", "subtract", "intersect"],
                        selection: Binding(get: { box.operation.rawValue }, set: { value in
                            if let operation = TriangleBooleanOperation(rawValue: value) { edit(.operation(operation, boxID: box.id)) }
                        }),
                        accessibilityID: "AdaEditor.CSG.Operation",
                        labels: operationLabels
                    )
                    .disabled(isReadOnly)
                }
            }
            Text(L10n.text("CSG Evaluation Order"))
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(theme.editorColors.muted)
            ForEach(selection.boxes) { box in
                Button(action: { edit(.select(box.id)) }) {
                    HStack(spacing: 6) {
                        Text(box.name).font(.system(size: 12)).lineLimit(1)
                        Spacer(minLength: 2)
                        Text(L10n.tr(rowLabel(box, base: base?.id)))
                            .font(.system(size: 11))
                            .foregroundColor(theme.editorColors.muted)
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                    .background(box.id == selection.selectedBoxID ? theme.editorColors.blue.opacity(0.20) : .clear)
                }
                .buttonStyle(EditorChromeHoverButtonStyle(theme: theme))
                .accessibilityIdentifier("AdaEditor.CSG.Box.\(box.id)")
            }
            Text(L10n.text("CSG New Shape")).font(.system(size: 11))
            EditorEnumField(
                cases: CSGShape.allCases.map(\.rawValue),
                selection: Binding(get: { shapeToAdd.rawValue }, set: { value in
                    if let shape = CSGShape(rawValue: value) { shapeToAdd = shape }
                }),
                accessibilityID: "AdaEditor.CSG.NewShape",
                labels: Self.shapeLabels
            )
            .disabled(isReadOnly || selection.boxes.count >= CSGGroupSource.maximumBoxes)
            HStack(spacing: 4) {
                Button(action: { edit(.addShape(shapeToAdd, groupID: selection.groupID)) }) {
                    HStack(spacing: 4) {
                        Text("\u{E145}").font(AdaEditorMaterialSymbolFont.font(size: 15))
                        Text(L10n.text("Add CSG Shape")).font(.system(size: 11))
                    }
                    .padding(.horizontal, 6)
                    .frame(height: 26)
                }
                    .buttonStyle(EditorFieldButtonStyle(theme: theme))
                    .disabled(isReadOnly || selection.boxes.count >= CSGGroupSource.maximumBoxes)
                    .accessibilityIdentifier("AdaEditor.CSG.AddBox")
                Spacer(minLength: 0)
                orderButton("\u{E5CE}", title: "Move CSG Operation Up", index: index, delta: -1)
                orderButton("\u{E5CF}", title: "Move CSG Operation Down", index: index, delta: 1)
            }
            surfaceFields
            if let status {
                HStack(alignment: .top, spacing: 6) {
                    Text(resultSymbol).font(AdaEditorMaterialSymbolFont.font(size: 15))
                    Text(L10n.tr(resultKey)).font(.system(size: 11))
                }
                .foregroundColor(status == .failed ? Color.red : theme.editorColors.muted)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.editorColors.surfaceElevated)
                .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 4).allowsHitTesting(false) }
                .accessibilityIdentifier("AdaEditor.CSG.Result")
            }
        }
        .foregroundColor(theme.editorColors.text)
    }

    private var surfaceFields: some View {
        let checker = EditorCSGScene.checkerTexture
        let cases = ["", checker] + textureReferences
        let textures = cases.contains(selection.texture) ? cases : cases + [selection.texture]
        let labels = Dictionary(
            textures.filter(EditorCSGScene.supportsTexture).map { ($0, String($0.dropFirst("@res://".count))) },
            uniquingKeysWith: { first, _ in first }
        ).merging(["": "CSG Plain", checker: "CSG UV Checker"], uniquingKeysWith: { _, label in label })
        let presets = ["1", "2", "4", "8"]
        let repeats = presets.contains(selection.uvRepeats) ? presets : presets + [selection.uvRepeats]
        return VStack(alignment: .leading, spacing: 6) {
            Text(L10n.text("CSG Texture")).font(.system(size: 11))
            EditorEnumField(
                cases: textures,
                selection: Binding(get: { selection.texture }, set: { edit(.texture($0, groupID: selection.groupID)) }),
                accessibilityID: "AdaEditor.CSG.Texture",
                labels: labels
            )
            Text(L10n.text("CSG UV Repeat")).font(.system(size: 11))
            EditorEnumField(
                cases: repeats,
                selection: Binding(get: { selection.uvRepeats }, set: { value in
                    if let repeats = Int(value) { edit(.uvRepeats(repeats, groupID: selection.groupID)) }
                }),
                accessibilityID: "AdaEditor.CSG.UVRepeats",
                labels: Dictionary(uniqueKeysWithValues: repeats.map { ($0, $0 + "×") })
            )
        }
        .disabled(isReadOnly)
    }

    private var resultKey: String {
        switch status {
        case .ready: "CSG Result Ready"
        case .empty: "CSG Empty Result"
        case .failed: "CSG Result Unavailable"
        case .pending, nil: "CSG Rebuilding"
        }
    }

    private var resultSymbol: String {
        switch status {
        case .ready: "\u{E86C}"
        case .empty: "\u{E88E}"
        case .failed: "\u{E000}"
        case .pending, nil: "\u{E863}"
        }
    }

    private func rowLabel(_ box: EditorCSGInspectorSelection.Box, base: String?) -> String {
        if !box.enabled {
            return "CSG Box Disabled"
        }
        if box.id == base {
            return "CSG Base"
        }
        return operationLabels[box.operation.rawValue] ?? "Union"
    }

    private func orderButton(_ symbol: String, title: String, index: Int?, delta: Int) -> some View {
        let enabled = !isReadOnly && index.map { selection.boxes.indices.contains($0 + delta) } == true
        return EditorSceneToolbarButton(
            title: title,
            symbol: symbol,
            identifier: "AdaEditor.CSG.Move.\(delta)",
            isEnabled: enabled
        ) {
            guard let index else {
                return
            }
            edit(.moveBox(selection.boxes[index].id, groupID: selection.groupID, delta: delta))
        }
        .background(theme.editorColors.surfaceElevated)
        .overlay { adaEditorPanelBorder(theme: theme, cornerRadius: 4).allowsHitTesting(false) }
    }
}
