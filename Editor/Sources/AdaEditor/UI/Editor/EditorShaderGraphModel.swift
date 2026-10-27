@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation
import Yams

enum EditorShaderGraphFileError: Error { case unavailable, changedOnDisk, unsavedChanges, readOnly }

/// The document owns authored values/history; viewport navigation and GPU preview are separate state.
@Observable
@MainActor
final class EditorShaderGraphModel {
    let url: URL?
    let canvas = EditorNodeCanvasState()
    var canvasViewportSize = Size(width: 480, height: 400)
    private(set) var graph: ShaderGraph?
    var selection = Set<String>() { didSet { selectedWire = nil } }
    var selectedWire: EditorNodeCanvasWire?
    var expandedPorts = Set<String>()
    private(set) var isDirty = false
    private(set) var isReadOnly = false
    private(set) var issue: (any Error)?
    private(set) var validation: ShaderGraphDiagnostic?
    private(set) var semanticRevision: UInt64 = 0
    private(set) var layoutRevision: UInt64 = 0
    @ObservationIgnored var onChange: ((Bool) -> Void)?
    @ObservationIgnored var onSaved: (() -> Void)?
    @ObservationIgnored private var savedData: Data?
    @ObservationIgnored private var savedGraph: ShaderGraph?
    @ObservationIgnored private var transaction: Snapshot?
    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []

    private struct Snapshot {
        let graph: ShaderGraph
        let selection: Set<String>
        var selectedWire: EditorNodeCanvasWire?
    }

    init(url: URL?) {
        self.url = url
        reload()
    }

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }
    var selectedNode: ShaderGraph.Node? { graph?.nodes.first { selection.contains($0.id) } }

    func reload(discardChanges: Bool = false) {
        guard !isDirty || discardChanges else {
            issue = EditorShaderGraphFileError.unsavedChanges
            return
        }
        do {
            guard let url else { throw EditorShaderGraphFileError.unavailable }
            let data = try Data(contentsOf: url)
            let loaded = try YAMLDecoder().decode(ShaderGraph.self, from: data)
            graph = loaded
            savedGraph = loaded
            savedData = data
            isReadOnly =
                (try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
                || !FileManager.default.isWritableFile(atPath: url.path)
                || loaded.nodes.contains { ShaderGraph.Operation(rawValue: $0.kind) == nil || $0.id.isEmpty }
                || Set(loaded.nodes.map(\.id)).count != loaded.nodes.count
            selection = selection.intersection(Set(loaded.nodes.map(\.id)))
            undoStack = []
            redoStack = []
            transaction = nil
            isDirty = false
            issue = nil
            validate()
            semanticRevision &+= 1
            layoutRevision &+= 1
            onChange?(true)
        } catch {
            issue = error
            graph = nil
            isReadOnly = true
            undoStack = []
            redoStack = []
            transaction = nil
            isDirty = false
        }
    }

    @discardableResult
    func save() -> Bool {
        endTransaction()
        do {
            guard !isReadOnly else { throw EditorShaderGraphFileError.readOnly }
            guard let url, let graph else { throw EditorShaderGraphFileError.unavailable }
            guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw EditorShaderGraphFileError.readOnly }
            _ = try graph.lowered()
            guard try Data(contentsOf: url) == savedData else { throw EditorShaderGraphFileError.changedOnDisk }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(graph)
            try data.write(to: url, options: .atomic)
            savedData = data
            savedGraph = graph
            isDirty = false
            issue = nil
            onSaved?()
            onChange?(false)
            return true
        } catch { issue = error; return false }
    }

    @discardableResult
    func edit(semantic: Bool = true, _ change: (inout ShaderGraph) -> Void) -> Bool {
        guard !isReadOnly, let current = graph else {
            return false
        }
        var candidate = current
        change(&candidate)
        guard candidate != current else {
            return false
        }
        if transaction == nil {
            undoStack.append(.init(graph: current, selection: selection, selectedWire: selectedWire))
            trimHistory()
            redoStack = []
        }
        graph = candidate
        selection.formIntersection(Set(candidate.nodes.map(\.id)))
        didEdit(semantic: semantic)
        return true
    }

    func beginTransaction() {
        guard transaction == nil, let graph, !isReadOnly else {
            return
        }
        transaction = .init(graph: graph, selection: selection, selectedWire: selectedWire)
    }

    func endTransaction() {
        guard let before = transaction else {
            return
        }
        transaction = nil
        if graph != before.graph {
            undoStack.append(before)
            trimHistory()
            redoStack = []
        }
    }

    func cancelTransaction() {
        guard let before = transaction else {
            return
        }
        transaction = nil
        adopt(before)
    }

    func undo() {
        endTransaction()
        guard !isReadOnly, let current = graph, let previous = undoStack.popLast() else {
            return
        }
        redoStack.append(.init(graph: current, selection: selection, selectedWire: selectedWire))
        adopt(previous)
    }

    func redo() {
        guard !isReadOnly, let current = graph, let next = redoStack.popLast() else {
            return
        }
        undoStack.append(.init(graph: current, selection: selection, selectedWire: selectedWire))
        adopt(next)
    }

    func moveNode(_ id: String, to position: ShaderGraph.Position) {
        guard position.x.isFinite, position.y.isFinite, graph?.nodes.contains(where: { $0.id == id }) == true else {
            return
        }
        edit(semantic: false) { $0.layout[id] = position }
    }

    func editNode(_ id: String, _ change: (inout ShaderGraph.Node) -> Void) {
        edit { graph in
            if let index = graph.nodes.firstIndex(where: { $0.id == id }) { change(&graph.nodes[index]) }
        }
    }

    /// Allows a valid edge while another port is still being authored. Full graph validation
    /// remains responsible for incomplete nodes; local preflight prevents bad types and cycles.
    func canConnect(_ source: ShaderGraph.Link, to target: String, port: String) -> Bool {
        guard !isReadOnly, let graph,
            let from = graph.nodes.first(where: { $0.id == source.node }),
            let destination = graph.nodes.first(where: { $0.id == target }),
            let actual = graph.outputPorts(for: from)[source.port], let expected = graph.inputPorts(for: destination)[port],
            actual == expected || (actual == .float && expected != .bool && expected != .texture2D)
        else {
            return false
        }
        guard Set(graph.nodes.map(\.id)).count == graph.nodes.count else {
            return false
        }
        let lookup = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        var pending = [source.node]
        var visited = Set<String>()
        while let id = pending.popLast() {
            if id == target {
                return false
            }
            if visited.insert(id).inserted { pending.append(contentsOf: lookup[id]?.inputs.values.map(\.node) ?? []) }
        }
        return true
    }

    @discardableResult
    func connect(_ source: ShaderGraph.Link, to target: String, port: String) -> Bool {
        guard canConnect(source, to: target, port: port) else {
            return false
        }
        return edit { graph in
            if let index = graph.nodes.firstIndex(where: { $0.id == target }) { graph.nodes[index].inputs[port] = source }
        }
    }

    func removeSelection() {
        if let wire = selectedWire {
            guard canvasWires.contains(wire) else { selectedWire = nil; return }
            editNode(wire.target.node) { $0.inputs[wire.target.port] = nil }
            return
        }
        guard let graph else {
            return
        }
        let removed = selection.subtracting([graph.output])
        edit { graph in
            graph.nodes.removeAll { removed.contains($0.id) }
            for id in removed { graph.layout.removeValue(forKey: id) }
            for id in graph.groups.keys { graph.groups[id]?.nodes.removeAll { removed.contains($0) } }
            graph.groups = graph.groups.filter { !$0.value.nodes.isEmpty }
            for index in graph.nodes.indices { graph.nodes[index].inputs = graph.nodes[index].inputs.filter { !removed.contains($0.value.node) } }
        }
    }

    private func adopt(_ snapshot: Snapshot) {
        let semantic = graph?.nodes != snapshot.graph.nodes || graph?.target != snapshot.graph.target || graph?.renderSettings != snapshot.graph.renderSettings
        graph = snapshot.graph
        selection = snapshot.selection
        selectedWire = snapshot.selectedWire
        didEdit(semantic: semantic)
    }

    private func didEdit(semantic: Bool) {
        isDirty = graph != savedGraph
        issue = nil
        layoutRevision &+= 1
        if semantic { semanticRevision &+= 1; validate() }
        onChange?(semantic)
    }

    private func validate() {
        validation = nil
        do { if let graph { _ = try graph.lowered() } } catch let error as ShaderGraphDiagnostic { validation = error } catch { issue = error }
    }

    private func trimHistory() {
        if undoStack.count > 100 { undoStack.removeFirst(undoStack.count - 100) }
    }
}
