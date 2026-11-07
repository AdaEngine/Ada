@_spi(AdaEngine) import AdaEngine
import Foundation

extension EditorAnimationGraphModel {
    var canvasItems: [EditorNodeCanvasItem] {
        graph.nodes.enumerated().map { index, node in
            let inputs: [EditorNodeCanvasPort] = node.kind == .clip ? [] : node.inputs.indices.map {
                .init(id: String($0), title: L10n.tr(node.kind == .additive && $0 == 0 ? "Base" : "Input") + " \($0 + 1)", type: "pose")
            } + [.init(id: "new", title: L10n.tr("+ Input"), type: "pose")]
            return .init(id: node.id, title: node.id == graph.root ? node.id + " → " + L10n.tr("Output") : node.id,
                position: positions[node.id] ?? Vector2(Float(index % 4) * 280, Float(index / 4) * 240), inputs: inputs,
                outputs: [.init(id: "pose", title: L10n.tr("Pose"), type: "pose")],
                subtitle: node.kind == .clip ? clipLabels[node.clip] ?? node.clip : L10n.tr(node.kind.rawValue),
                hasError: validationMessage != nil && node.id == selectedNodeID)
        }
    }

    var canvasWires: [EditorNodeCanvasWire] {
        graph.nodes.flatMap { node in
            node.inputs.enumerated().map { index, input in
                .init(source: .init(node: input.node, port: "pose", isOutput: true),
                      target: .init(node: node.id, port: String(index), isOutput: false), type: "pose")
            }
        }
    }

    func canvasInteraction() -> EditorNodeCanvasInteraction {
        let pointer = EditorNodeCanvasInteraction()
        pointer.select = { [weak self] ids in
            guard let self else { return }
            canvasSelection = ids
            selectedWire = nil
            if let first = ids.sorted().first { selectedNodeID = first }
            onInspect?()
        }
        pointer.selectWire = { [weak self] wire in
            self?.selectedWire = wire
            self?.selectedNodeID = wire.target.node
            self?.onInspect?()
        }
        pointer.begin = { [weak self] in self?.beginCanvasTransaction() }
        pointer.commit = { [weak self] in self?.endCanvasTransaction() }
        pointer.cancel = { [weak self] in self?.cancelCanvasTransaction() }
        pointer.move = { [weak self] values in
            guard let self else { return }
            for (id, point) in values { positions[id] = point }
            layoutRevision &+= 1
        }
        pointer.connect = { [weak self, weak pointer] source, target in
            self?.connectCanvas(source, to: target, replacing: pointer?.replacedInput)
        }
        return pointer
    }

    func connectCanvas(_ source: EditorNodeCanvasEndpoint, to target: EditorNodeCanvasEndpoint,
                       replacing: EditorNodeCanvasEndpoint? = nil) {
        if replacing == target { return }
        guard source.isOutput, !target.isOutput, source.port == "pose", source.node != target.node,
              graph.nodes.contains(where: { $0.id == source.node }),
              let index = graph.nodes.firstIndex(where: { $0.id == target.node && $0.kind != .clip }) else { return }
        var candidate = graph
        var targetPort = Int(target.port)
        var movedInput = AnimationGraph.Input(node: source.node)
        if let replacing, replacing != target,
           let oldNode = candidate.nodes.firstIndex(where: { $0.id == replacing.node }),
           let oldPort = Int(replacing.port), candidate.nodes[oldNode].inputs.indices.contains(oldPort) {
            movedInput = candidate.nodes[oldNode].inputs.remove(at: oldPort)
            movedInput.node = source.node
            if oldNode == index, let port = targetPort, oldPort < port { targetPort = port - 1 }
        }
        // Replacing an input on the same card is index-sensitive; resolve against the final draft.
        if target.port == "new" { candidate.nodes[index].inputs.append(movedInput) }
        else if let port = targetPort, candidate.nodes[index].inputs.indices.contains(port) {
            if replacing != nil { candidate.nodes[index].inputs[port] = movedInput }
            else { candidate.nodes[index].inputs[port].node = source.node }
        } else { return }
        var visiting: Set<String> = []
        var visited: Set<String> = []
        let dependencies = candidate.nodes.reduce(into: [String: [String]]()) { $0[$1.id] = $1.inputs.map(\.node) }
        func acyclic(_ id: String) -> Bool {
            if visiting.contains(id) { return false }
            if visited.contains(id) { return true }
            visiting.insert(id)
            for child in dependencies[id] ?? [] where !acyclic(child) { return false }
            visiting.remove(id)
            visited.insert(id)
            return true
        }
        guard candidate.nodes.allSatisfy({ acyclic($0.id) }) else {
            canvasError = L10n.tr("Animation graph connections cannot form a cycle.")
            return
        }
        graph = candidate
        canvasError = nil
    }

    func beginCanvasTransaction() {
        guard transaction == nil else { return }
        transaction = .init(graph: graph, positions: positions)
    }

    func endCanvasTransaction() {
        guard let before = transaction else { return }
        transaction = nil
        func effective(_ graph: AnimationGraph, _ positions: [String: Vector2]) -> [String: Vector2] {
            graph.nodes.enumerated().reduce(into: [:]) { result, entry in
                result[entry.element.id] = positions[entry.element.id] ?? Vector2(Float(entry.offset % 4) * 280, Float(entry.offset / 4) * 240)
            }
        }
        if before.graph == graph, effective(before.graph, before.positions) == effective(graph, positions) {
            positions = before.positions
            return
        }
        if before.graph != graph || before.positions != positions {
            undoStack.append(before)
            redoStack.removeAll()
        }
    }

    func cancelCanvasTransaction() {
        guard let before = transaction else { return }
        transaction = nil
        restoreCanvas(before)
    }

    func undoCanvas() {
        guard transaction == nil, let before = undoStack.popLast() else { return }
        redoStack.append(.init(graph: graph, positions: positions))
        restoreCanvas(before)
    }

    func redoCanvas() {
        guard transaction == nil, let after = redoStack.popLast() else { return }
        undoStack.append(.init(graph: graph, positions: positions))
        restoreCanvas(after)
    }

    private func restoreCanvas(_ snapshot: CanvasSnapshot) {
        restoring = true
        graph = snapshot.graph
        positions = snapshot.positions
        restoring = false
        selectedWire = nil
        canvasSelection = canvasSelection.filter { id in graph.nodes.contains { $0.id == id } }
        if !graph.nodes.contains(where: { $0.id == selectedNodeID }) { selectedNodeID = graph.root }
        layoutRevision &+= 1
    }

    func deleteCanvasSelection() {
        if let wire = selectedWire, canvasWires.contains(wire), let port = Int(wire.target.port) {
            editNode(wire.target.node) { node in
                if node.inputs.indices.contains(port) { node.inputs.remove(at: port) }
            }
            selectedWire = nil
        } else {
            beginCanvasTransaction()
            let ids = canvasSelection.isEmpty ? [selectedNodeID] : canvasSelection.sorted()
            for id in ids { selectedNodeID = id; removeSelectedNode() }
            endCanvasTransaction()
            canvasSelection = []
        }
    }
}
