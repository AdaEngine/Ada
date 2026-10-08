import AdaECS

/// References another scene that should be instantiated beneath this entity.
///
/// The entity's transform becomes the root transform for the referenced scene,
/// allowing scene assets to be reused as prefabs.
@Component
public struct SceneInstance: Codable, Hashable, Sendable {
    /// Portable resource reference to the nested scene.
    public var scene: String

    public init(scene: String = "") {
        self.scene = scene
    }
}
