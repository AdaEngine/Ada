import Math

/// One static-mesh placement in a shared batch; identity remains stable when its transform changes.
public struct Mesh3DInstance: Equatable, Sendable {
    public let id: UInt64
    public var transform: Transform3D
    public var color: Vector4

    public init(id: UInt64, transform: Transform3D = .identity, color: Vector4 = .one) {
        self.id = id
        self.transform = transform
        self.color = color
    }
}
