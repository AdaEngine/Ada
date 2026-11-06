/// Optional native curve settings for a key. Easing applies to its outgoing segment.
/// Bézier handles are per component; Hermite derivatives remain in the key's tangent fields.
public struct AnimationKeyCurve: Codable, Equatable, Sendable {
    public var easing: AnimationEasing?
    public var incoming: [AnimationBezierHandle]?
    public var outgoing: [AnimationBezierHandle]?

    public init(easing: AnimationEasing? = nil, incoming: [AnimationBezierHandle]? = nil, outgoing: [AnimationBezierHandle]? = nil) {
        self.easing = easing
        self.incoming = incoming
        self.outgoing = outgoing
    }
}
