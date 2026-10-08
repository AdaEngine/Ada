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
    var graph = AnimationGraph(root: "Output", nodes: []) { didSet { validate() } }
    var selectedNodeID = "Output"
    var rig: SkeletalRig? { didSet { validate() } }
    var clips: [SkeletalAnimationClip] = [] { didSet { validate() } }
    private(set) var validationMessage: String? = "This model has no animation clips."

    func configure(asset: ModelAsset3D, graph: AnimationGraph? = nil) {
        rig = asset.animationRig
        clips = asset.animationClips
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
            try graph.validate(rig: rig, clips: clips)
            validationMessage = nil
        } catch {
            validationMessage = error.localizedDescription
        }
    }

    var validGraph: AnimationGraph? { validationMessage == nil ? graph : nil }
    var selectedNode: AnimationGraph.Node? { graph.nodes.first { $0.id == selectedNodeID } }

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
    }

    func removeSelectedNode() {
        guard selectedNodeID != graph.root else {
            return
        }
        let id = selectedNodeID
        graph.nodes.removeAll { $0.id == id }
        for index in graph.nodes.indices { graph.nodes[index].inputs.removeAll { $0.node == id } }
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
    func setAnimationGraph(_ graph: AnimationGraph?, target: EditorSkeletalAnimationTarget, autoplay: Bool? = nil) throws -> Bool {
        guard let document = sceneDocument(id: target.documentID), !document.isReadOnly,
            document.sceneModel?.entities.contains(where: { $0.id == target.entityID }) == true
        else { return false }
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
