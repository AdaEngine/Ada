/// Marks a generated entity that must be reconstructed instead of saved in a World or Scene.
/// Its hierarchy descendants are omitted as well. Direct Entity encoding is unaffected.
public struct TransientEntity: Component, Sendable {
    public init() {}
}
