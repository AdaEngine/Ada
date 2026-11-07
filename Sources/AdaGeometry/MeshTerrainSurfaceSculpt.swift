import Foundation
import Math

/// A retained brush on the triangle sheet selected by a surface query.
public struct MeshTerrainSurfaceSculpt: Codable, Equatable, Sendable {
    public enum Operation: Codable, Equatable, Sendable {
        case smooth
        case flatten(point: Vector3)
    }

    public let sectionID: UUID?
    public let center: Vector3
    public let normal: Vector3
    public let sourceID: UInt32
    public let radius: Float
    public let strength: Float
    public let operation: Operation

    public init(sectionID: UUID? = nil, center: Vector3, normal: Vector3, sourceID: UInt32, radius: Float, strength: Float, operation: Operation) {
        self.sectionID = sectionID
        self.center = center
        self.normal = normal
        self.sourceID = sourceID
        self.radius = radius
        self.strength = strength
        self.operation = operation
    }

    func validate() throws {
        func finite(_ value: Vector3) -> Bool { value.x.isFinite && value.y.isFinite && value.z.isFinite }
        guard finite(center), normal.squaredLength.isFinite, normal.squaredLength > 0.000001,
            sourceID < TrianglePatchClosure.closureSource, radius.isFinite, radius > 0, radius <= 256,
            strength.isFinite, (0...1).contains(strength)
        else { throw TriangleGeometryError.invalidInput }
        if case let .flatten(point) = operation, !finite(point) { throw TriangleGeometryError.invalidInput }
    }
}
