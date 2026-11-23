@_spi(AdaEngine) import AdaEngine
import Foundation

struct EditorLocomotionInspectorState: Equatable {
    enum Catalog: Equatable {
        case loading
        case unavailable
        case failed(String)
        case ready(names: [String], ambiguous: Set<String>)
    }

    var catalog: Catalog
    var hasController: Bool
    var hasPlaybackConflict: Bool

    @MainActor
    init(
        entity: EditorSceneEntity,
        owner: Entity?,
        world: World?,
        isLoading: Bool,
        sourceURL: URL?,
        resourceRootURL: URL?
    ) {
        let modelPayload = entity.components[EditorBuiltInComponentType.model3DSource]
        let reference = modelPayload?["source"]?.stringValue ?? ""
        hasController = entity.components[String(reflecting: CharacterController3DComponent.self)] != nil
            || owner?.components[CharacterController3DComponent.self] != nil
        let graph = modelPayload?["animationGraph"]
        hasPlaybackConflict = (graph != nil && graph != .null)
            || entity.components[String(reflecting: ModelAnimationPlayback3DComponent.self)] != nil
            || owner?.components[ModelAnimationPlayback3DComponent.self] != nil

        if reference.isEmpty {
            catalog = .unavailable
        } else if isLoading || world == nil {
            catalog = .loading
        } else if let state = owner?.components[Model3DSourceState.self],
                  let resolved = try? EditorModelResource.resolve(reference, sourceURL: sourceURL, resourceRootURL: resourceRootURL),
                  state.reference.source == resolved.path {
            if let error = state.error {
                catalog = .failed(error)
            } else if let root = state.rootEntityID.flatMap({ world?.getEntityByID($0) }) {
                let clips = root.components[ModelAnimation3DComponent.self]?.player.clips ?? []
                let counts = clips.reduce(into: [String: Int]()) { counts, clip in
                    if !clip.name.isEmpty { counts[clip.name, default: 0] += 1 }
                }
                catalog = .ready(
                    names: counts.keys.filter { counts[$0] == 1 }.sorted(),
                    ambiguous: Set(counts.keys.filter { (counts[$0] ?? 0) > 1 })
                )
            } else {
                catalog = .unavailable
            }
        } else {
            catalog = .unavailable
        }
    }
}
