import AdaAnimation
import AdaECS
import AdaTransform

/// Persistent transform state and track names shared by Editor Play and exported scenes.
public struct SceneTransformAnimationValues: Codable, KeyframeAnimatable, Sendable {
    public var transform: Transform
    public init(transform: Transform) { self.transform = transform }
    public func apply(to entityId: Entity.ID, in world: World) { world.insert(transform, for: entityId) }
    public static var clipSchema: KeyframeClipSchema<Self> {
        var schema = KeyframeClipSchema<Self>()
        schema.register("transform.position.x", keyPath: \.transform.position.x, type: Float.self)
        schema.register("transform.position.y", keyPath: \.transform.position.y, type: Float.self)
        schema.register("transform.position.z", keyPath: \.transform.position.z, type: Float.self)
        schema.register("transform.scale.x", keyPath: \.transform.scale.x, type: Float.self)
        schema.register("transform.scale.y", keyPath: \.transform.scale.y, type: Float.self)
        schema.register("transform.scale.z", keyPath: \.transform.scale.z, type: Float.self)
        return schema
    }
}
