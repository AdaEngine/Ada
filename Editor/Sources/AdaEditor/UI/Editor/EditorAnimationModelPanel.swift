@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorAnimationModelWorkspace: View {
    let workspace: EditorAnimationAssetWorkspace
    @State private var startWidth: Float?
    @State private var hoverHelp: String?
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            let width = workspace.timeline.showsModelPanel ? min(workspace.timeline.modelPanelWidth, max(100, geometry.size.width * 0.45)) : 0
            HStack(spacing: 0) {
                EditorAnimationModelPanel(workspace: workspace).frame(width: width)
                    .mask(RectangleShape()).allowsHitTesting(width > 0)
                RectangleShape().fill(theme.editorColors.border).frame(width: width > 0 ? 6 : 0)
                    .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                        if startWidth == nil { startWidth = width }
                        workspace.timeline.modelPanelWidth = max(100, min(max(100, geometry.size.width * 0.45), (startWidth ?? width) + value.translation.width))
                    }.onEnded { _ in startWidth = nil })
                    .accessibilityIdentifier("AdaEditor.Model.Hierarchy.Divider")
                VStack(spacing: 0) {
                    HStack(spacing: 5) {
                        control("Model", glyph: "☰", selected: workspace.timeline.showsModelPanel) { workspace.timeline.showsModelPanel.toggle() }
                        control("Frame model", glyph: "⌖") { workspace.camera.reset() }
                        control("Frame Selection", glyph: "◎") { workspace.camera.frameSelection(workspace.preview.selectedWorldPoints()) }
                        control(workspace.camera.isOrthographic ? "Orthographic" : "Perspective", glyph: workspace.camera.isOrthographic ? "O" : "P",
                            selected: workspace.camera.isOrthographic) { workspace.camera.isOrthographic.toggle() }
                        control(workspace.preview.showsBones ? "Hide bones" : "Show bones", glyph: "◆", selected: workspace.preview.showsBones) { workspace.preview.showsBones.toggle() }
                        control("Preview Settings", glyph: "⚙") { workspace.timeline.inspectorMode = "preview"; workspace.revealInspector?() }
                        Spacer(minLength: 0)
                    }.padding(4).frame(height: 30)
                    EditorModelPreviewViewport(model: workspace.preview, camera: workspace.camera)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(width: geometry.size.width, height: geometry.size.height)
                .overlay(anchor: .topLeading) {
                    if let hoverHelp {
                        Text(hoverHelp).font(.system(size: 11)).padding(6).background(theme.editorColors.surfaceElevated)
                            .offset(x: width + 6, y: 32).allowsHitTesting(false)
                    }
                }
        }
    }

    private func control(_ title: String, glyph: String, selected: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(glyph).font(.system(size: 13)).frame(width: 26, height: 26) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: selected, horizontalPadding: 0))
            .onHover { hoverHelp = $0 ? L10n.tr(title) : nil }
            .accessibilityIdentifier("AdaEditor.Animation.View.\(title)")
    }
}

struct EditorAnimationModelPanel: View {
    let workspace: EditorAnimationAssetWorkspace
    private var model: EditorAnimationTimelineModel { workspace.timeline }
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr("Model")).font(.system(size: 12, weight: .semibold)).padding(6)
            TextField(L10n.tr("Filter Nodes"), text: Binding(get: { model.search }, set: { model.search = $0 }))
                .textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors, height: 30))
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.hierarchyRows) { row in
                        HStack(spacing: 4) {
                            Button {
                                if !model.collapsedNodes.insert(row.nodeID).inserted { model.collapsedNodes.remove(row.nodeID) }
                            } label: { Text(model.collapsedNodes.contains(row.nodeID) ? "▸" : "▾").font(.system(size: 11)).frame(width: 16, height: 24) }
                                .buttonStyle(DefaultButtonStyle())
                            Button { model.selectNode(row.nodeID) } label: {
                                Text(symbol(row.nodeID) + " " + row.label).font(.system(size: 11)).lineLimit(1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }.buttonStyle(DefaultButtonStyle())
                                .overlay { EditorAnimationHierarchyRowInput(model: model, nodeID: row.nodeID) }
                                .accessibilityIdentifier("AdaEditor.Model.Node.\(row.nodeID)")
                        }.padding(.leading, Float(min(8, row.depth)) * 10).frame(height: 24)
                            .foregroundColor(model.selectedNodes.contains(row.nodeID) ? theme.editorColors.blue : theme.editorColors.text)
                            .background(model.selectedNodes.contains(row.nodeID) ? theme.editorColors.blue.opacity(0.14) : Color.clear)
                            .contextMenu { Button(L10n.tr("Select Subtree")) { model.selectSubtree(row.nodeID) } }
                    }
                }.frame(maxWidth: .infinity, alignment: .topLeading)
            }
            modifierList
        }.padding(4).background(theme.editorColors.surface)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .accessibilityIdentifier("AdaEditor.Model.Hierarchy")
    }

    private func symbol(_ id: String) -> String {
        guard let index = model.nodes.firstIndex(where: { $0.id == id }), let asset = workspace.preview.asset else { return "◇" }
        if asset.skins.contains(where: { $0.joints.contains(index) }) { return "◆" }
        return asset.nodes.indices.contains(index) && asset.nodes[index].meshIndex != nil ? "▣" : "◇"
    }

    private var modifierList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                model.inspectorMode = "modifiers"; workspace.revealInspector?()
            } label: { Text(L10n.tr("Modifiers")).font(.system(size: 12, weight: .semibold)) }
                .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: model.inspectorMode == "modifiers"))
            HStack(spacing: 4) {
                modifierAction("+ Two-bone IK") { try workspace.addModifier(.twoBone) }
                modifierAction("+ FABRIK") { try workspace.addModifier(.fabrik) }
            }
            ScrollView(.vertical, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(workspace.modifiers?.stack.modifiers ?? [], id: \.id) { modifier in
                        Button {
                            workspace.selectedModifierID = modifier.id
                            model.inspectorMode = "modifiers"
                            workspace.revealInspector?()
                        } label: {
                            Text((modifier.enabled ? "● " : "○ ") + (modifier.name ?? L10n.tr(modifier.kind == .twoBone ? "Two-bone IK" : "FABRIK")))
                                .font(.system(size: 11)).lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }.buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: workspace.selectedModifierID == modifier.id))
                            .accessibilityIdentifier("AdaEditor.Animation.Modifier.\(modifier.id)")
                    }
                }.padding(.trailing, 8)
            }.frame(height: min(90, Float(workspace.modifiers?.stack.modifiers.count ?? 0) * 29))
        }.padding(4).accessibilityIdentifier("AdaEditor.Animation.Modifiers")
    }

    private func modifierAction(_ title: String, action: @escaping () throws -> Void) -> some View {
        Button { model.perform(action) } label: { Text(L10n.tr(title)).font(.system(size: 11)).lineLimit(2) }
            .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors)).disabled(workspace.sourceLibrary == nil)
    }
}

private struct EditorAnimationHierarchyRowInput: UIViewRepresentable {
    let model: EditorAnimationTimelineModel
    let nodeID: String
    func makeUIView(in _: Context) -> EditorAnimationHierarchyRowView {
        let view = EditorAnimationHierarchyRowView(frame: .zero)
        view.backgroundColor = .clear
        return view
    }
    func updateUIView(_ view: EditorAnimationHierarchyRowView, in _: Context) { view.model = model; view.nodeID = nodeID }
}

private final class EditorAnimationHierarchyRowView: UIView {
    weak var model: EditorAnimationTimelineModel?
    var nodeID = ""
    override func onMouseEvent(_ event: MouseEvent) {
        guard event.button == .left, event.phase == .began else { return }
        model?.selectNode(nodeID, additive: event.modifierKeys.contains(.main) || event.modifierKeys.contains(.control), range: event.modifierKeys.contains(.shift))
    }
}
