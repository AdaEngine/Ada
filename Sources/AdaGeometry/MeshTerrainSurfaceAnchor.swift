import Foundation
import Math

/// A durable paint or placement anchor, separate from a generated triangle index.
/// The base frame is terrain-local; a source frame follows the retained operand.
public struct MeshTerrainSurfaceAnchor: Codable, Equatable, Sendable {
    public enum Frame: Codable, Equatable, Sendable {
        case base
        case source(UUID)
    }

    public let frame: Frame
    public let section: UUID
    public let faceID: UInt32
    public let point: Vector3
    public let normal: Vector3

    public init(frame: Frame, section: UUID, faceID: UInt32, point: Vector3, normal: Vector3) {
        self.frame = frame
        self.section = section
        self.faceID = faceID
        self.point = point
        self.normal = normal
    }

    public static func capture(section: UUID, surface: TriangleSurface, hit: TriangleSurfaceHit, document: MeshTerrainDocument) throws -> Self {
        let face = hit.triangleIndex
        guard (0..<surface.indices.count / 3).contains(face),
            surface.faceSources.isEmpty || surface.faceSources.indices.contains(face),
            surface.faceIDs.isEmpty || surface.faceIDs.indices.contains(face) else { throw TriangleGeometryError.invalidInput }
        let sourceID = surface.faceSources.isEmpty ? 0 : surface.faceSources[face]
        let faceID = surface.faceIDs.isEmpty ? UInt32(face) : surface.faceIDs[face]
        if sourceID == 0 {
            return .init(frame: .base, section: section, faceID: faceID, point: hit.position, normal: hit.normal)
        }
        guard let source = document.modifiers.first(where: { $0.enabled && $0.sourceID == sourceID }) else {
            throw TriangleGeometryError.invalidInput
        }
        try ScalarSolid.validateTransform(source.transform)
        let position = (source.transform.inverse * Vector4(hit.position, 1)).xyz
        let normal = Self.transpose(source.transform, times: hit.normal)
        let anchor = Self(frame: .source(source.id), section: section, faceID: faceID, point: position, normal: normal)
        try anchor.validate()
        return anchor
    }

    func validate() throws {
        guard point.x.isFinite, point.y.isFinite, point.z.isFinite, normal.squaredLength.isFinite,
            normal.squaredLength > 0.000001 else { throw TriangleGeometryError.invalidInput }
    }

    func resolved(in document: MeshTerrainDocument) throws -> (point: Vector3, normal: Vector3, sourceID: UInt32)? {
        try validate()
        switch frame {
        case .base: return (point, normal.normalized, 0)
        case let .source(id):
            guard let modifier = document.modifiers.first(where: { $0.id == id && $0.enabled }) else { return nil }
            let position = (modifier.transform * Vector4(point, 1)).xyz
            let direction = Self.transpose(modifier.transform.inverse, times: normal)
            guard position.x.isFinite, position.y.isFinite, position.z.isFinite, direction.squaredLength.isFinite,
                direction.squaredLength > 0.000001 else { throw TriangleGeometryError.invalidInput }
            return (position, direction.normalized, modifier.sourceID)
        }
    }

    private static func transpose(_ matrix: Transform3D, times vector: Vector3) -> Vector3 {
        .init(matrix.x.xyz.dot(vector), matrix.y.xyz.dot(vector), matrix.z.xyz.dot(vector))
    }
}
