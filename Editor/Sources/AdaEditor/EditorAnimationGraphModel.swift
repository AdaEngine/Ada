@_spi(AdaEngine) import AdaEngine
import Foundation
import Observation

/// Scene payloads remain structured YAML; the inspector and runtime share the same graph schema.
enum EditorAnimationGraphPayload {
    static func decode(_ value: EditorSceneValue?) throws -> AnimationGraph? {
        guard let value, value != .null else {
            return nil
        }
        let data = try JSONSerialization.data(withJSONObject: value.jsonCompatibleValue)
        return try JSONDecoder().decode(AnimationGraph.self, from: data)
    }

    static func encode(_ graph: AnimationGraph) throws -> EditorSceneValue {
        try JSONDecoder().decode(EditorSceneValue.self, from: JSONEncoder().encode(graph))
    }
}

@Observable
@MainActor
final class EditorAnimationGraphModel {
    var graph = AnimationGraph(root: "Output", nodes: []) {
        didSet {
            if oldValue != graph { revision = UUID().uuidString }
            if oldValue != graph, !restoring, transaction == nil {
                undoStack.append(.init(graph: oldValue, positions: positions))
                if undoStack.count > 100 { undoStack.removeFirst() }
                redoStack.removeAll()
            }
            if oldValue != graph { selectedWire = nil }
            validate()
        }
    }
    var selectedNodeID = "Output"
    private(set) var revision = UUID().uuidString
    var rig: SkeletalRig? { didSet { validate() } }
    var clips: [SkeletalAnimationClip] = [] { didSet { validate() } }
    var clipLabels: [String: String] = [:]
    private(set) var validationMessage: String? = "This model has no animation clips."
    let canvas = EditorNodeCanvasState()
    var canvasViewportSize = Size.zero
    var canvasSelection: Set<String> = []
    var selectedWire: EditorNodeCanvasWire?
    var positions: [String: Vector2] = [:]
    var canvasError: String?
    var layoutRevision: UInt64 = 0
    var undoStack: [CanvasSnapshot] = []
    var redoStack: [CanvasSnapshot] = []
    var transaction: CanvasSnapshot?
    var restoring = false
    @ObservationIgnored var onInspect: (() -> Void)?

    struct CanvasSnapshot {
        var graph: AnimationGraph
        var positions: [String: Vector2]
    }

    func configure(asset: ModelAsset3D, graph: AnimationGraph? = nil, authoredClips: [SkeletalAnimationClip] = [], clipLabels: [String: String] = [:]) {
        restoring = true
        defer { restoring = false }
        rig = asset.animationRig
        clips = asset.animationClips + authoredClips
        self.clipLabels = clipLabels
        self.graph = graph ?? Self.defaultGraph(clip: clips.first?.name)
        selectedNodeID = self.graph.root
    }

    static func defaultGraph(clip: String?) -> AnimationGraph {
        guard let clip else {
            return AnimationGraph(root: "Output", nodes: [])
        }
        return AnimationGraph(
            root: "Output",
            nodes: [
                .init(id: "Clip1", clip: clip),
                .init(id: "Output", kind: .blend, inputs: [.init(node: "Clip1")]),
            ]
        )
    }

    private func validate() {
        guard let rig, !clips.isEmpty else {
            validationMessage = "This model has no animation clips."
            return
        }
        do {
            try checkGraphBudget(graph)
            try graph.validate(rig: rig, clips: clips)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    var validGraph: AnimationGraph? { validationMessage == nil ? graph : nil }
    var selectedNode: AnimationGraph.Node? { graph.nodes.first { $0.id == selectedNodeID } }

    func checkRevision(_ expected: String) throws {
        guard expected == revision, transaction == nil else {
            throw AnimationAuthoringError(.conflict, itemID: "graph", message: L10n.tr("Graph changed or a canvas gesture is active; inspect and retry."))
        }
    }

    func applyGraph(_ candidate: AnimationGraph, expectedRevision: String) throws {
        try checkRevision(expectedRevision)
        try checkGraphBudget(candidate)
        guard candidate.nodes.count <= 4096, candidate.nodes.reduce(0, { $0 + $1.inputs.count + $1.events.count }) <= 16_384,
              try JSONEncoder().encode(candidate).count <= 65_536 else {
            throw AnimationAuthoringError(.limitExceeded, itemID: "graph", message: L10n.tr("Graph requests must fit in 64 KiB."))
        }
        graph = candidate
        if !graph.nodes.contains(where: { $0.id == selectedNodeID }) { selectedNodeID = graph.root }
        canvasSelection = canvasSelection.filter { id in graph.nodes.contains { $0.id == id } }
    }

    /// Bound editor compilation before the runtime expands masks and allocates per-card pose buffers.
    private func checkGraphBudget(_ candidate: AnimationGraph) throws {
        let ids = candidate.nodes.map(\.id)
        guard Set(ids).count == ids.count, ids.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 256 }) else {
            throw AnimationAuthoringError(.invalidTrack, itemID: "graph", message: L10n.tr("Graph node IDs must be unique, nonempty and at most 256 UTF-8 bytes."))
        }
        guard let rig else { return }
        var depths = Array(repeating: 1, count: rig.nodes.count)
        for index in rig.evaluationOrder {
            if let parent = rig.nodes[index].parentIndex { depths[index] = depths[parent] + 1 }
        }
        let ancestry = depths.reduce(0, +)
        var work = 0, inputs = 0
        for node in candidate.nodes {
            inputs += node.inputs.count
            for input in node.inputs {
                for entry in input.mask?.joints ?? [] {
                    work += entry.includesDescendants ? ancestry : rig.nodes.count
                    guard work <= 4_000_000 else { throw graphBudgetError() }
                }
            }
        }
        let poseCells = rig.nodes.count * (candidate.nodes.count + inputs)
        let morphCells = rig.nodes.reduce(0, { $0 + ($1.morphRestWeights?.count ?? 0) }) * candidate.nodes.count
        guard poseCells <= 1_000_000, morphCells <= 1_000_000 else { throw graphBudgetError() }
    }

    private func graphBudgetError() -> AnimationAuthoringError {
        .init(.limitExceeded, itemID: "graph", message: L10n.tr("Graph preview exceeds the pose or mask compilation budget; reduce cards or mask entries."))
    }

    func editNode(_ id: String, _ edit: (inout AnimationGraph.Node) -> Void) {
        guard let index = graph.nodes.firstIndex(where: { $0.id == id }) else {
            return
        }
        edit(&graph.nodes[index])
    }

    func addNode(_ kind: AnimationGraph.Node.Kind) {
        var number = 1
        let prefix = kind == .clip ? "Clip" : kind == .blend ? "Blend" : "Additive"
        while graph.nodes.contains(where: { $0.id == "\(prefix)\(number)" }) { number += 1 }
        let id = "\(prefix)\(number)"
        let input = graph.nodes.first { $0.kind == .clip }.map { [AnimationGraph.Input(node: $0.id)] } ?? []
        graph.nodes.append(.init(id: id, kind: kind, clip: clips.first?.name ?? "", inputs: kind == .clip ? [] : input))
        selectedNodeID = id
        canvasSelection = [id]
        onInspect?()
    }

    func removeSelectedNode() {
        guard selectedNodeID != graph.root else {
            return
        }
        let id = selectedNodeID
        var candidate = graph
        candidate.nodes.removeAll { $0.id == id }
        for index in candidate.nodes.indices { candidate.nodes[index].inputs.removeAll { $0.node == id } }
        graph = candidate
        selectedNodeID = graph.root
    }

    func addInput(to id: String) {
        guard let candidate = graph.nodes.first(where: { $0.id != id && $0.kind == .clip }) else {
            return
        }
        editNode(id) { $0.inputs.append(.init(node: candidate.id)) }
    }
}

struct EditorSkeletalAnimationTarget: Equatable {
    let documentID: String
    let entityID: String
    let source: Model3DSource
    let sceneURL: URL?
}

extension EditorViewModel {
    var skeletalAnimationTarget: EditorSkeletalAnimationTarget? {
        if let asset = workbench.animationAssetDocument, asset.kind == .model3D,
            ["glb", "gltf"].contains(asset.fileExtension.lowercased()), let reference = asset.assetReference {
            return .init(documentID: asset.id, entityID: "", source: Model3DSource(source: reference),
                sceneURL: asset.absolutePath.map { URL(fileURLWithPath: $0) })
        }
        guard let document = workbench.activeSceneDocument,
            let entity = document.sceneModel?.selectedEntity(),
            let payload = entity.components[EditorBuiltInComponentType.model3DSource],
            let source = try? EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.model3DSource, payload: payload) as? Model3DSource
        else { return nil }
        return .init(documentID: document.id, entityID: entity.id, source: source, sceneURL: document.absolutePath.map { URL(fileURLWithPath: $0) })
    }
}

extension EditorWorkbenchViewModel {
    /// One scene-history transaction, shared by Save/reopen, duplicate and runtime Play.
    @discardableResult
    func setAnimationGraph(_ graph: AnimationGraph?, target: EditorSkeletalAnimationTarget, autoplay: Bool? = nil, asset: ModelAsset3D? = nil) throws -> Bool {
        guard let document = sceneDocument(id: target.documentID), !document.isReadOnly,
            document.sceneModel?.entities.contains(where: { $0.id == target.entityID }) == true
        else { return false }
        if let asset, let service = animationService {
            guard let payload = document.sceneModel?.entities.first(where: { $0.id == target.entityID })?.components[EditorBuiltInComponentType.model3DSource],
                let current = try EditorComponentRegistry.decode(typeName: EditorBuiltInComponentType.model3DSource, payload: payload) as? Model3DSource,
                current == target.source else {
                throw AnimationAuthoringError(.conflict, itemID: target.entityID, message: "Model binding changed; refresh the graph before applying it.")
            }
            var candidate = current
            candidate.animationGraph = graph
            let libraries = try service.savedDocuments(references: current.animationLibraries, sceneURL: target.sceneURL).map(\.library)
            _ = try candidate.resolvedAnimationClips(importedClips: asset.animationClips, rig: asset.animationRig, libraries: libraries)
        }
        let encoded = try graph.map(EditorAnimationGraphPayload.encode)
        updateSceneModelDocument(id: target.documentID, status: graph == nil ? "Animation graph removed" : "Animation graph applied") { scene in
            guard let index = scene.entities.firstIndex(where: { $0.id == target.entityID }),
                scene.entities[index].components[EditorBuiltInComponentType.model3DSource] != nil
            else { return }
            scene.entities[index].components[EditorBuiltInComponentType.model3DSource]?["animationGraph"] = encoded
            if let autoplay { scene.entities[index].components[EditorBuiltInComponentType.model3DSource]?["autoplay"] = .bool(autoplay) }
        }
        return true
    }
}
