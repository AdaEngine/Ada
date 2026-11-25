@_spi(AdaEngine) import AdaEngine
import Foundation
import Math

extension EditorInspectorSidebar {
    func decalInspector(_ viewport: EditorSceneViewportModel) -> some View {
        let editing = viewport.decalEditing
        return VStack(alignment: .leading, spacing: 8) {
            if editing.enabled {
                Text(L10n.text("Image for new decals")).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
                assetReferenceField(
                    fieldID: "Decal.New",
                    value: editing.draftImage,
                    text: Binding(get: { editing.draftImage }, set: { editing.draftImage = $0 })
                )
                HStack(spacing: 6) {
                    decalButton("Place decal", identifier: "Place", prominent: true) { editing.begin() }
                        .disabled(editing.draftImage.isEmpty || editing.isPlacing || editing.isApplying)
                    decalButton("Done", identifier: "Done") { editing.setEnabled(false) }
                }
            }
            if !editing.entries.isEmpty {
                ForEach(editing.entries) { entry in
                    let title = entry.images.color.split(separator: "/").last.map(String.init) ?? entry.images.color
                    Button { editing.selection = entry.id } label: {
                        Text(title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, selected: editing.selection == entry.id))
                    .accessibilityIdentifier("AdaEditor.Inspector.Decals.Entry.\(entry.id)")
                }
            }
            if let entry = editing.selectedEntry {
                decalImage("Decal image", field: "Color", entry: entry, key: \.color, viewport: viewport)
                decalOptionalImage("Decal normal map", field: "Normal", entry: entry, key: \.normal, viewport: viewport)
                decalOptionalImage("Decal roughness map", field: "Roughness", entry: entry, key: \.roughness, viewport: viewport)
                EditorDecalDimensions(entry: entry) { updated in
                    editing.replace(updated, viewport: viewport)
                }
                .id(entry.id)
                .disabled(editing.isApplying)
                HStack(spacing: 6) {
                    decalButton("Move", identifier: "Move") {
                        viewport.setTerrainEditing(false)
                        editing.setEnabled(true)
                        editing.begin(move: true)
                    }
                    decalButton("Delete", identifier: "Delete") { editing.deleteSelected(viewport: viewport) }
                }
                .disabled(editing.isPlacing || editing.isApplying)
            }
            if let message = editing.isApplying ? "Applying decal…" : editing.message ?? editing.selectedError(in: viewport) {
                Text(L10n.tr(message)).font(.system(size: 11))
                    .foregroundColor(theme.editorColors.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("AdaEditor.Inspector.Decals.Status")
            }
        }
    }

    private func decalImage(
        _ label: String, field: String, entry: Decal3DSource.Entry, key: WritableKeyPath<Decal3DImages, String>, viewport: EditorSceneViewportModel
    ) -> some View {
        let editing = viewport.decalEditing
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(label)).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            assetReferenceField(
                fieldID: "Decal.\(entry.id).\(field)",
                value: entry.images[keyPath: key],
                text: Binding(get: { entry.images[keyPath: key] }, set: { value in
                    guard !value.isEmpty, var updated = editing.selectedEntry, updated.id == entry.id else {
                        return
                    }
                    updated.images[keyPath: key] = value
                    editing.replace(updated, viewport: viewport)
                })
            )
        }
    }

    private func decalOptionalImage(
        _ label: String, field: String, entry: Decal3DSource.Entry, key: WritableKeyPath<Decal3DImages, String?>, viewport: EditorSceneViewportModel
    ) -> some View {
        let editing = viewport.decalEditing
        return VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(label)).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            assetReferenceField(
                fieldID: "Decal.\(entry.id).\(field)",
                value: entry.images[keyPath: key] ?? "",
                text: Binding(get: { entry.images[keyPath: key] ?? "" }, set: { value in
                    guard var updated = editing.selectedEntry, updated.id == entry.id else {
                        return
                    }
                    updated.images[keyPath: key] = value.isEmpty ? nil : value
                    editing.replace(updated, viewport: viewport)
                })
            )
            if entry.images[keyPath: key] != nil {
                decalButton("Clear image", identifier: "Clear.\(field)") {
                    guard var updated = editing.selectedEntry, updated.id == entry.id else {
                        return
                    }
                    updated.images[keyPath: key] = nil
                    editing.replace(updated, viewport: viewport)
                }
            }
        }
    }

    private func decalButton(_ title: String, identifier: String, prominent: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(L10n.tr(title)).font(.system(size: 12))
        }
        .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors, prominent: prominent))
        .accessibilityIdentifier("AdaEditor.Inspector.Decals.\(identifier)")
    }
}

private struct EditorDecalDimensions: View {
    let entry: Decal3DSource.Entry
    let apply: (Decal3DSource.Entry) -> Bool
    @State private var width = ""
    @State private var height = ""
    @State private var depth = ""
    @State private var rotation = ""
    @State private var priority = ""
    @State private var invalid = false
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L10n.text("Decal size (m)")).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            HStack(spacing: 4) {
                EditorAnimationAxisField(axis: "X", text: $width, identifier: "AdaEditor.Inspector.Decals.Size.X")
                EditorAnimationAxisField(axis: "Y", text: $height, identifier: "AdaEditor.Inspector.Decals.Size.Y")
                EditorAnimationAxisField(axis: "Z", text: $depth, identifier: "AdaEditor.Inspector.Decals.Size.Z")
            }
            HStack(spacing: 5) {
                number("Rotation", text: $rotation)
                number("Priority", text: $priority)
            }
            Button(action: commit) { Text(L10n.text("Apply decal settings")).font(.system(size: 12)) }
                .buttonStyle(EditorAnimationButtonStyle(colors: theme.editorColors))
                .accessibilityIdentifier("AdaEditor.Inspector.Decals.Apply")
            if invalid {
                Text(L10n.text("Enter a positive size, a rotation and a whole-number priority."))
                    .font(.system(size: 11)).foregroundColor(theme.editorColors.text)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: entry) { _, _ in refresh() }
    }

    private func number(_ title: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.tr(title)).font(.system(size: 11)).foregroundColor(theme.editorColors.muted)
            TextField("", text: text).textFieldStyle(EditorAnimationFieldStyle(colors: theme.editorColors))
                .accessibilityIdentifier("AdaEditor.Inspector.Decals.\(title)")
        }
    }

    private func refresh() {
        width = String(entry.size.x)
        height = String(entry.size.y)
        depth = String(entry.size.z)
        rotation = String(entry.rotationDegrees)
        priority = String(entry.images.priority)
        invalid = false
    }

    private func commit() {
        guard let x = parsed(width), let y = parsed(height), let z = parsed(depth), min(x, y, z) > 0,
              let rotation = parsed(rotation), let priority = Int(priority) else {
            invalid = true
            return
        }
        var updated = entry
        updated.size = Vector3(x, y, z)
        updated.rotationDegrees = rotation
        updated.images.priority = priority
        invalid = !apply(updated)
    }

    private func parsed(_ value: String) -> Float? {
        guard let number = Float(value.replacingOccurrences(of: ",", with: ".")), number.isFinite else {
            return nil
        }
        return number
    }
}
