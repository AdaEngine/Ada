@_spi(AdaEngine) import AdaEngine
import Foundation

/// Node and connection authoring shared by the model preview and scene Animator.
struct EditorAnimationGraphEditor: View {
    let model: EditorAnimationGraphModel
    @Environment(\.theme) private var theme

    var body: some View {
        GeometryReader { geometry in
            content(height: max(80, geometry.size.height - 76))
        }
        .padding(8)
        .foregroundColor(theme.editorColors.text)
        .accessibilityIdentifier("AdaEditor.AnimationGraph.Editor")
    }

    private func content(height: Float) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("Output").font(.system(size: 11))
                EditorEnumField(
                    cases: model.graph.nodes.map(\.id), 
                    selection: Binding(get: { model.graph.root }, set: { model.graph.root = $0 }),
                    accessibilityID: "AdaEditor.AnimationGraph.Output"
                )
                .frame(width: 130)
                ForEach(AnimationGraph.Node.Kind.allCases, id: \.rawValue) { kind in
                    button("+ \(kind.rawValue)", id: "Add.\(kind.rawValue)") { model.addNode(kind) }
                }
            }
            HStack(alignment: .top, spacing: 12) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(model.graph.nodes, id: \.id) { node in
                            Button(action: { model.selectedNodeID = node.id }) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(node.id + (node.id == model.graph.root ? " → Output" : ""))
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(node.kind == .clip ? node.clip : node.inputs.map(\.node).joined(separator: " + "))
                                        .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
                                }
                                .padding(7)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(
                                    RoundedRectangleShape(cornerRadius: 5).fill(
                                        node.id == model.selectedNodeID ? theme.editorColors.blue.opacity(0.18) : theme.editorColors.surface
                                    )
                                    )
                            }
                            .buttonStyle(DefaultButtonStyle())
                            .accessibilityIdentifier("AdaEditor.AnimationGraph.Node.\(node.id)")
                        }
                        button("Remove node", id: "RemoveNode") { model.removeSelectedNode() }
                            .disabled(model.selectedNodeID == model.graph.root)
                    }
                }
                .frame(width: 150, height: height)
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if let node = model.selectedNode {
                            nodeEditor(node).id(node.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: height)
            }
            .frame(height: height)
            if let error = model.validationMessage {
                Text(error).font(.system(size: 11)).foregroundColor(.red)
                    .accessibilityIdentifier("AdaEditor.AnimationGraph.Validation")
            } else {
                Text("Blend fills unused weight with rest pose. Additive: first input is base; other inputs add rest-relative motion.")
                    .font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func nodeEditor(_ node: AnimationGraph.Node) -> some View {
        HStack {
            Text(node.id).font(.system(size: 12, weight: .semibold))
            EditorEnumField(
                cases: AnimationGraph.Node.Kind.allCases.map(\.rawValue),
                selection: Binding(
                    get: { node.kind.rawValue },
                    set: { value in
                        guard let kind = AnimationGraph.Node.Kind(rawValue: value) else {
                            return
                        }
                        model.editNode(node.id) {
                            $0.kind = kind
                            if kind == .clip { $0.inputs = [] } else { $0.events = [] }
                        }
                        if kind != .clip && model.selectedNode?.inputs.isEmpty == true { model.addInput(to: node.id) }
                    }
                ), accessibilityID: "AdaEditor.AnimationGraph.Kind"
            )
            .frame(width: 100)
        }
        if node.kind == .clip {
            EditorEnumField(
                cases: model.clips.map(\.name),
                selection: Binding(
                    get: { node.clip },
                    set: { value in
                        model.editNode(node.id) { $0.clip = value }
                    }
                ), accessibilityID: "AdaEditor.AnimationGraph.Clip"
                )
            HStack {
                number("Speed", value: node.speed, id: "Speed") { value in model.editNode(node.id) { $0.speed = value } }
                button(node.repeats ? "Loop: On" : "Loop: Off", id: "Loop") { model.editNode(node.id) { $0.repeats.toggle() } }
            }
            eventsEditor(node)
        } else {
            ForEach(Array(node.inputs.indices), id: \.self) { edge in
                inputEditor(node, edge: edge)
            }
            button("+ Input", id: "AddInput") { model.addInput(to: node.id) }
        }
    }

    private func inputEditor(_ node: AnimationGraph.Node, edge: Int) -> some View {
        let input = node.inputs[edge]
        return VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Text(node.kind == .additive && edge == 0 ? "Base" : "Input \(edge + 1)").font(.system(size: 11))
                EditorEnumField(
                    cases: model.graph.nodes.filter { $0.id != node.id }.map(\.id),
                    selection: Binding(
                        get: { input.node }, set: { value in model.editNode(node.id) { $0.inputs[edge].node = value } }
                    ),
                    accessibilityID: "AdaEditor.AnimationGraph.Input.\(edge)"
                )
                number("Weight", value: Double(input.weight), id: "Weight.\(edge)") { value in
                    model.editNode(node.id) { $0.inputs[edge].weight = Float(value) }
                }
                button("×", id: "RemoveInput.\(edge)") { model.editNode(node.id) { $0.inputs.remove(at: edge) } }
            }
            button(input.mask == nil ? "All bones · Add mask" : "Masked bones · Clear mask", id: "Mask.\(edge)") {
                model.editNode(node.id) { $0.inputs[edge].mask = input.mask == nil ? .init() : nil }
            }
            if let mask = input.mask {
                maskEditor(node, edge: edge, mask: mask)
            }
        }
        .padding(6)
        .background(RoundedRectangleShape(cornerRadius: 5).fill(theme.editorColors.surface))
    }

    @ViewBuilder
    private func maskEditor(_ node: AnimationGraph.Node, edge: Int, mask: AnimationGraph.Mask) -> some View {
        number("Other bones", value: Double(mask.defaultWeight), id: "MaskDefault.\(edge)") { value in
            model.editNode(node.id) { $0.inputs[edge].mask?.defaultWeight = Float(value) }
        }
        ForEach(Array(mask.joints.indices), id: \.self) { entry in
            let joint = mask.joints[entry]
            HStack(spacing: 4) {
                EditorEnumField(
                    cases: jointNames,
                    selection: Binding(
                        get: { jointName(joint.nodeIndex) },
                        set: { value in
                            guard let index = jointNames.firstIndex(of: value) else {
                                return
                            }
                            model.editNode(node.id) { $0.inputs[edge].mask?.joints[entry].nodeIndex = index }
                        }
                    ), accessibilityID: "AdaEditor.AnimationGraph.Joint.\(edge).\(entry)"
                    )
                number("Weight", value: Double(joint.weight), id: "JointWeight.\(edge).\(entry)") { value in
                    model.editNode(node.id) { $0.inputs[edge].mask?.joints[entry].weight = Float(value) }
                }
                button(joint.includesDescendants ? "Subtree" : "Bone only", id: "Descendants.\(edge).\(entry)") {
                    model.editNode(node.id) { $0.inputs[edge].mask?.joints[entry].includesDescendants.toggle() }
                }
                button("×", id: "RemoveJoint.\(edge).\(entry)") { model.editNode(node.id) { $0.inputs[edge].mask?.joints.remove(at: entry) } }
            }
        }
        button("+ Bone", id: "AddJoint.\(edge)") {
            model.editNode(node.id) { $0.inputs[edge].mask?.joints.append(.init(nodeIndex: 0)) }
        }
    }

    @ViewBuilder
    private func eventsEditor(_ node: AnimationGraph.Node) -> some View {
        Text("CLIP EVENTS").font(.system(size: 10, weight: .semibold)).foregroundColor(theme.editorColors.muted)
        ForEach(Array(node.events.indices), id: \.self) { index in
            HStack(spacing: 5) {
                number("Seconds", value: node.events[index].time, id: "EventTime.\(index)") { value in
                    model.editNode(node.id) { $0.events[index].time = value }
                }
                TextField(
                    "Event name",
                    text: Binding(
                        get: { node.events[index].name },
                        set: { value in
                            model.editNode(node.id) { $0.events[index].name = value }
                        }
                    )
                ).font(.system(size: 11)).frame(width: 110, height: 28)
                    .accessibilityIdentifier("AdaEditor.AnimationGraph.EventName.\(index)")
                TextField(
                    "Payload",
                    text: Binding(
                        get: { node.events[index].payload },
                        set: { value in
                            model.editNode(node.id) { $0.events[index].payload = value }
                        }
                    )
                ).font(.system(size: 11)).frame(width: 100, height: 28)
                button("×", id: "RemoveEvent.\(index)") { model.editNode(node.id) { $0.events.remove(at: index) } }
            }
        }
        button("+ Event", id: "AddEvent") { model.editNode(node.id) { $0.events.append(.init(time: 0, name: "Event")) } }
    }

    private var jointNames: [String] {
        (model.rig?.nodes.indices ?? 0..<0).map(jointName)
    }

    private func jointName(_ index: Int) -> String {
        guard let rig = model.rig, rig.nodes.indices.contains(index) else {
            return "\(index): Missing bone"
        }
        return "\(index): \(rig.nodes[index].name ?? "Node")"
    }

    private func number(_ title: String, value: Double, id: String, set: @escaping (Double) -> Void) -> some View {
        EditorAnimationGraphNumberField(title: title, value: value, identifier: id, set: set)
    }

    private func button(_ title: String, id: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Text(title).font(.system(size: 11)).padding(4) }
            .buttonStyle(DefaultButtonStyle())
            .accessibilityIdentifier("AdaEditor.AnimationGraph.\(id)")
    }
}

/// Keep intermediate input such as "0." or "-" while updating valid values live.
private struct EditorAnimationGraphNumberField: View {
    let title: String
    let value: Double
    let identifier: String
    let set: (Double) -> Void
    @State private var draft = ""
    @Environment(\.theme) private var theme

    var body: some View {
        HStack(spacing: 4) {
            Text(title).font(.system(size: 10)).foregroundColor(theme.editorColors.muted)
            TextField(title, text: $draft)
                .font(.system(size: 11)).frame(width: 54, height: 28)
                .background(RoundedRectangleShape(cornerRadius: 4).fill(theme.editorColors.background))
                .accessibilityIdentifier("AdaEditor.AnimationGraph.\(identifier)")
        }
        .onAppear { draft = String(format: "%.6g", value) }
        .onChange(of: draft) { _, text in
            if let number = Double(text), number.isFinite { set(number) }
        }
        .onChange(of: value) { _, number in
            if let current = Double(draft), abs(current - number) <= max(1, abs(number)) * 0.000001 {
                return
            }
            draft = String(format: "%.6g", number)
        }
    }
}
