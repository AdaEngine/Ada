import Foundation

/// Validated payload of the `AdaSprite.Mesh2D` scene component, the 2D mesh Ada Studio authors.
///
/// The Web Player turns this into a generated mesh with a flat-color canvas material. Validation lives here, apart
/// from the renderer, so an invalid scene is rejected before anything is spawned.
public struct AdaWebPlayerMesh2D: Equatable, Sendable {
    /// Primitives Studio offers for 2D meshes.
    public enum Primitive: String, Sendable {
        case quad = "Quad"
        case circle = "Circle"
    }

    /// Size Studio writes for a new 2D mesh.
    public static let defaultSize = 64.0
    /// Largest accepted size, inclusive.
    public static let maximumSize = 100_000.0

    public let primitive: Primitive
    public let size: Double

    /// - Parameters:
    ///   - mesh: Primitive name; `Quad` when absent.
    ///   - size: Edge length or diameter; ``defaultSize`` when absent.
    /// - Throws: ``AdaWebPlayerProjectError`` for an unsupported primitive or a size that is not finite, positive and
    ///   at most ``maximumSize``.
    public init(mesh: String?, size: Double?) throws {
        guard let primitive = Primitive(rawValue: mesh ?? Primitive.quad.rawValue) else {
            throw AdaWebPlayerProjectError.invalid("Unsupported 2D mesh primitive '\(mesh ?? "")'; use Quad or Circle.")
        }
        let size = size ?? Self.defaultSize
        guard size.isFinite, size > 0, size <= Self.maximumSize else {
            throw AdaWebPlayerProjectError.invalid("2D mesh size must be finite, positive and at most \(Int(Self.maximumSize)).")
        }
        self.primitive = primitive
        self.size = size
    }
}
