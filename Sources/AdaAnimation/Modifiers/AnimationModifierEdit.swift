/// An atomic semantic edit, shared by native controls, agents and developer Tools.
public struct AnimationModifierEdit: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case add, remove, move, update }
    public var kind: Kind
    public var modifierID: String?
    public var modifier: AnimationPoseModifier?
    public var index: Int?

    public init(kind: Kind, modifierID: String? = nil, modifier: AnimationPoseModifier? = nil, index: Int? = nil) {
        self.kind = kind; self.modifierID = modifierID; self.modifier = modifier; self.index = index
    }
}

extension AnimationModifierStack {
    /// Applies the entire transaction or leaves this stack unchanged.
    public mutating func apply(_ operations: [AnimationModifierEdit]) throws {
        guard operations.count <= 256 else { throw AnimationPoseModifierError.limitExceeded }
        var candidate = self
        for operation in operations {
            switch operation.kind {
            case .add:
                guard let modifier = operation.modifier, candidate.modifiers.count < 32 else { throw AnimationPoseModifierError.limitExceeded }
                let index = operation.index ?? candidate.modifiers.count
                guard (0...candidate.modifiers.count).contains(index) else { throw AnimationPoseModifierError.invalidModifier(modifier.id) }
                candidate.modifiers.insert(modifier, at: index)
            case .remove, .move, .update:
                guard let id = operation.modifierID, let current = candidate.modifiers.firstIndex(where: { $0.id == id }) else {
                    throw AnimationPoseModifierError.invalidModifier(operation.modifierID ?? "")
                }
                if operation.kind == .remove { candidate.modifiers.remove(at: current) }
                else if operation.kind == .move {
                    guard let index = operation.index, candidate.modifiers.indices.contains(index) else { throw AnimationPoseModifierError.invalidModifier(id) }
                    let modifier = candidate.modifiers.remove(at: current)
                    candidate.modifiers.insert(modifier, at: index)
                } else {
                    guard let modifier = operation.modifier, modifier.id == id else { throw AnimationPoseModifierError.invalidModifier(id) }
                    candidate.modifiers[current] = modifier
                }
            }
        }
        try candidate.validate()
        self = candidate
    }
}
