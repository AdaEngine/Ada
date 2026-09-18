@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorPhysicsShapesField: View {
    let text: Binding<String>
    var is3D = false
    @State private var numericDrafts: [String: String] = [:]
    @State private var errorMessage: String?
    @Environment(\.theme) private var theme

    private var shapes: [EditorSceneValue] {
        guard let values = try? JSONDecoder().decode([EditorSceneValue].self, from: Data(text.wrappedValue.utf8)) else {
            return []
        }
        return values
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(shapes.indices), id: \.self) { index in
                shapeRow(index)
            }
            if let errorMessage {
                Text(errorMessage).foregroundColor(.red)
            }
            Button("+ Add Shape") {}
                .contextMenu(opensOnPrimaryAction: true) {
                    ForEach(EditorPhysicsShapeValue.kinds(is3D: is3D), id: \.rawValue) { kind in
                        Button(kind.rawValue.capitalized) {
                            var values = shapes
                            values.append(EditorPhysicsShapeValue.make(kind, is3D: is3D))
                            save(values)
                        }
                    }
                }
                .accessibilityIdentifier("AdaEditor.Physics.Shapes.Add")
        }
        .font(.system(size: 11))
        .foregroundColor(theme.editorColors.text)
    }

    private func shapeRow(_ index: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Shape \(index + 1)")
                Spacer()
                Button("−") {
                    var values = shapes
                    guard values.indices.contains(index) else {
                        return
                    }
                    values.remove(at: index)
                    numericDrafts = [:]
                    save(values)
                }
                .accessibilityIdentifier("AdaEditor.Physics.Shapes.Remove.\(index)")
            }
            EditorEnumField(cases: EditorPhysicsShapeValue.kinds(is3D: is3D).map(\.rawValue), selection: kindBinding(index))
            if let kind = EditorPhysicsShapeValue.kind(of: shapes[index]) {
                dimensions(index, kind: kind)
                if !is3D || kind == .sphere {
                    numberField("Offset X", index: index, kind: kind, property: is3D ? "center.x" : "offset.x")
                    numberField("Offset Y", index: index, kind: kind, property: is3D ? "center.y" : "offset.y")
                    if is3D {
                        numberField("Offset Z", index: index, kind: kind, property: "center.z")
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangleShape(cornerRadius: 6).fill(theme.editorColors.surface))
    }

    @ViewBuilder
    private func dimensions(_ index: Int, kind: EditorPhysicsShapeValue.Kind) -> some View {
        switch kind {
        case .box:
            numberField("Width", index: index, kind: kind, property: is3D ? "halfExtents.x" : "halfWidth", scale: 2, positive: true)
            numberField("Height", index: index, kind: kind, property: is3D ? "halfExtents.y" : "halfHeight", scale: 2, positive: true)
            if is3D {
                numberField("Depth", index: index, kind: kind, property: "halfExtents.z", scale: 2, positive: true)
            }
        case .circle,
            .sphere:
            numberField("Radius", index: index, kind: kind, property: "radius", positive: true)
        case .polygon:
            if case let .array(vertices) = shapes[index].value(at: EditorPhysicsShapeValue.path(kind, "verticies")[...]) {
                ForEach(Array(vertices.indices), id: \.self) { vertex in
                    numberField("Point \(vertex + 1) X", index: index, kind: kind, property: "verticies.\(vertex).x")
                    numberField("Point \(vertex + 1) Y", index: index, kind: kind, property: "verticies.\(vertex).y")
                }
            }
        }
    }

    private func kindBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: {
                guard shapes.indices.contains(index) else {
                    return "box"
                }
                return EditorPhysicsShapeValue.kind(of: shapes[index])?.rawValue ?? "box"
            },
            set: { rawValue in
                guard let kind = EditorPhysicsShapeValue.Kind(rawValue: rawValue), shapes.indices.contains(index) else {
                    return
                }
                var values = shapes
                values[index] = EditorPhysicsShapeValue.make(kind, is3D: is3D)
                numericDrafts = [:]
                save(values)
            }
        )
    }

    private func numberField(
        _ title: String,
        index: Int,
        kind: EditorPhysicsShapeValue.Kind,
        property: String,
        scale: Double = 1,
        positive: Bool = false
    ) -> some View {
        HStack {
            Text(title).frame(width: 90, alignment: .leading)
            TextField(
                "0",
                text: Binding(
                    get: {
                        if let draft = numericDrafts["\(index).\(property)"] {
                            return draft
                        }
                        guard shapes.indices.contains(index) else {
                            return "0"
                        }
                        let value = shapes[index].value(at: EditorPhysicsShapeValue.path(kind, property)[...])?.doubleValue ?? 0
                        return EditorSceneModelFormatting.format(value * scale)
                    },
                    set: { rawValue in
                        numericDrafts["\(index).\(property)"] = rawValue
                        guard
                            let number = Double(rawValue), Float(number).isFinite, !positive || number > 0,
                            shapes.indices.contains(index)
                        else {
                            return
                        }
                        var values = shapes
                        values[index].setValue(.double(number / scale), at: EditorPhysicsShapeValue.path(kind, property)[...])
                        save(values)
                    }
                )
            )
            .textFieldStyle(PlainTextFieldStyle())
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.background))
            .accessibilityIdentifier("AdaEditor.Physics.Shapes.\(index).\(property)")
        }
    }

    private func save(_ values: [EditorSceneValue]) {
        guard values.allSatisfy(EditorPhysicsShapeValue.isValid) else {
            errorMessage = "A polygon needs at least three non-collinear points."
            return
        }
        errorMessage = nil
        text.wrappedValue = EditorSceneValue.array(values).jsonString
    }
}
